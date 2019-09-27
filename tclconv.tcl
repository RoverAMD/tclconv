#!/usr/bin/env tclsh
# Creates bindings of Tcl code to Python/Ruby (currently offers support for seperate functions)

set tclconvScriptIdentity impl.tcl

namespace eval tclconv {
    proc optimize {str} {
        set str2 [string trim [string map {\t { }} $str]]
        set result ""
        set spacesCount 0
        for {set index 0} {$index < [string length $str2]} {incr index}  {
            set char [string index $str2 $index]
            if {$char == { }} {
                incr spacesCount
                if {$spacesCount < 2} {
                    set result "$result$char"
                }
            } else {
                set spacesCount 0
                set result "$result$char"
            }
        }
        return $result
    }
    
    proc optimizeEach {listing} {
        set result {}
        foreach item $listing {
            lappend result [tclconv::optimize $item]
        }
        return $result
    }
    
    
    proc matchStart {line line2} {
        if {[llength $line2] > [llength $line]} {
            return 0
        }
        for {set index 0} {$index < [llength $line2]} {incr index} {
            set char1 [string index $line $index]
            set char2 [string index $line2 $index]
            if {$char1 != $char2} {
                return 0
            }
        }
        return 1
    }
    
    proc splitPreserved {str how} {
        set items {}
        set item ""
        set inside 0
        for {set index 0 } {$index < [string length $str]} {incr index} {
            set char [string index $str $index]
            if {$char == "\{"} {
                incr inside
            } elseif {$char == "\}"} {
                set inside [expr {$inside - 1}]
            } elseif {$inside} {
                set item "$item$char"
            } elseif {$char == $how} {
                lappend items $item
                set item ""
            } else {
                set item "$item$char"
            }
        }
        if {[string length $item] > 0} {
            lappend items $item
        }
        return $items
    }
    
    proc unquote {str} {
        return [string map {{"} "\\\""} $str]
    }
    
    proc joinCorrectly {args {isRuby 0}} {
        set result {}
        foreach agp $args {
            foreach ag [split $agp { }] {
                set tmplt "'{' + @convr@($ag) + '} '"
                if {$isRuby} {
                    set tmplt "'{' + $ag.to_s + '} '"
                }
                lappend result $tmplt
            }
        }
        return [join $result { + }]
    }
    
    proc cgen_ruby {funcsDictL identity} {
        set runnerFunc "_[expr {round(rand() * 999999)}]_tclkickstart_rb"
        set codetemplate {
require 'fileutils'
        
def @func@(what)
    tempdir = '/tmp'
    path = File.absolute_path(File.dirname($0)) + '/@identity@'
    if ENV['OS'] == 'Windows_NT' then
        path = path.gsub("\\", '/')
        tempdir = ENV['TEMP'].to_s.gsub("\\", '/')
    end
    fn = tempdir + '/' + rand().to_s + '.tcl'
    File.write(fn, "source \"" + path + "\"; puts [" + what + "]")
    if ENV['OS'] == 'Windows_NT' then
        fn = fn.gsub('/', "\\")
    end
    o = `tclsh "#{fn}"`
    FileUtils.rm_rf(fn)
    return o
end
        }
        set codetemplate "[string map [list @func@ $runnerFunc @identity@ $identity] $codetemplate]\n\n"
        foreach item $funcsDictL {
            set funcres "def [dict get $item name] ("
            set argsjoin {}
            set cmda {}
            foreach argument [dict get $item args] {
                if {[llength $argument] > 1} {
                    lappend argsjoin "[lindex $argument 0]='[tclconv::unquote [lindex $argument 1]]'"
                } else {
                    lappend argsjoin $argument
                }
                lappend cmda $argument
            }
            set funcres "$funcres[join $argsjoin {, }])"
            set funcres "$funcres\n\treturn $runnerFunc ('[dict get $item orig] ' + [tclconv::joinCorrectly $cmda 1])\n\end\n\n"
            set codetemplate "$codetemplate$funcres"
        }
        return $codetemplate
    }
    
    proc cgen_python {funcsDictL identity} {
        set runnerFunc "_[expr {round(rand() * 999999)}]_tclkickstart"
        set convrFunc "_[expr {round(rand() * 999999)}]_tclconverttypes"
        set codetemplate {
import os
import subprocess
import datetime

def @convr@(tp):
    result = str(tp)
    if type(tp) is list:
        result = ''
        for element in tp:
            result += '{' + @convr@(element) + '} '
    elif type(tp) is str:
        return tp
    return result

def @func@(what):
    tempdir = '/tmp'
    path = os.path.abspath(os.path.dirname(__file__)) + '/@identity@'
    if os.name == 'nt':
        tempdir = os.getenv('TEMP').replace("\\", "/")
        path = path.replace('/', "\\")
    fn = tempdir + '/' + str(datetime.datetime.now().timestamp()) + '.tcl'
    with open(fn, 'w') as f:
        f.write('source "' + path + '"; puts [' + what + ']')
    if os.name == 'nt':
        fn = fn.replace('/', "\\")
    cmd = ['tclsh', fn]
    o = subprocess.check_output(cmd).decode('utf-8')
    os.remove(fn)
    return o.rstrip('\r\n').rstrip('\n')
    
        }
        set codetemplate "[string map [list @func@ $runnerFunc @identity@ $identity] $codetemplate]\n\n"
        foreach item $funcsDictL {
            set funcres "def [dict get $item name] ("
            set argsjoin {}
            set cmda {}
            foreach argument [dict get $item args] {
                if {[llength $argument] > 1} {
                    lappend argsjoin "[lindex $argument 0]='[tclconv::unquote [lindex $argument 1]]'"
                } else {
                    lappend argsjoin $argument
                }
                lappend cmda $argument
            }
            set funcres "$funcres[join $argsjoin {, }]):"
            set funcres "$funcres\n\treturn $runnerFunc ('[dict get $item orig] ' + [tclconv::joinCorrectly $cmda])\n\n"
            set codetemplate "$codetemplate$funcres"
        }
        return [string map [list @convr@ $convrFunc] $codetemplate]
    }
    
    proc convert {lines {lang ruby}} {
        set realLines [tclconv::optimizeEach $lines]
        set namespacev NULL
        set allFuncs {}
        foreach ln $realLines {
            if {[string length $ln] > 0} {
                set fchar [string index $ln 0]
                if {$fchar == "#"} {
                    if {[tclconv::matchStart $ln {#/endn}]} {
                        set namespacev NULL
                    } elseif {[tclconv::matchStart $ln {#/startn}]} {
                        set namespacev [lindex [split $ln { }] 1]
                    }
                } else {
                    set splitLn [tclconv::splitPreserved $ln { }]
                    set firstkw [lindex $splitLn 0]
                    if {$firstkw == "proc"} {
                        set fname [lindex $splitLn 1]
                        set origname $fname
                        set args [tclconv::splitPreserved [lindex $splitLn 2] { }]
                        if {$namespacev != "NULL"} {
                            set fname [join [list $namespacev $fname] _]
                            set origname [join [list $namespacev $origname] {::}]
                        }
                        lappend allFuncs [dict create type f name $fname args $args orig $origname]
                    } elseif {$firstkw == "namespace"} {
                        set secondkw [lindex $splitLn 1]
                        if {$secondkw == "eval"} {
                            set namespacev [lindex $splitLn 2]
                        }
                    }
                }
            }
        }
        global tclconvScriptIdentity
        return [tclconv::cgen_$lang $allFuncs $tclconvScriptIdentity]
    }
}

if {[info exists argv0] && $argv0 == [info script]} {
    if {$::argc < 2} {
        puts "Usage: tclsh $argv0 python SCRIPT"
        puts "       tclsh $argv0 ruby SCRIPT"
        exit 1
    }
    set lang [lindex $::argv 0]
    set fn [lindex $::argv 1]
    if {$lang != "ruby" && $lang != "python"} {
        puts "ERROR. Programming language \"$lang\" is not supported by TclConv."
        exit 2
    }
    set desc [open $fn r]
    set tclconvScriptIdentity [file tail $fn]
    set lines [split [read $desc] \n]
    close $desc
    puts [tclconv::convert $lines $lang]
    exit 0
}
