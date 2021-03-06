/// Mecca UT support
module mecca.runtime.ut;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

version(unittest):

import std.file: read;
import std.stdio;
import std.string;
import std.datetime;
import std.path: absolutePath, buildNormalizedPath;
import core.sys.posix.unistd: isatty;
import core.runtime: Runtime;

import mecca.lib.console;
import mecca.log;

shared static this() {
    // Disable pre-main unittests run
    Runtime.moduleUnitTester = (){return true;};
}

/**
 * Automatic main for UT compilations.
 *
 * Special main for UT compilations. This main accepts arguments that limit (by module) the UTs to run.
 */
@notrace int utMain(string[] argv) {
    int res = parseArgs(argv);
    if( res>0 )
        return res-1;

    ModuleInfo*[] modules;
    foreach(m; ModuleInfo) {
        if (m && m.unitTest) {
            if( !shouldRun(m.name) )
                continue;

            if( listModules )
                writeln(m.name);
            else
                modules ~= m;
        }
    }

    if( !runTests )
        return 0;

    size_t counter;
    bool failed = false;
    auto startTime = MonoTime.currTime();

    META!"Started UT of %s (a total of %s found)"(buildNormalizedPath(argv[0].absolutePath()), modules.length);
    logLine(FG.icyan("Started UT of %s (a total of %s found)".format(buildNormalizedPath(argv[0].absolutePath()), modules.length)));

    foreach(m; modules) {
        counter++;
        DEBUG!"#LOADAVG %s"(cast(immutable char[])read("/proc/loadavg"));
        META!"Running UT of %s"(m.name);
        logLine(FG.yellow("Running UT of ") ~ FG.iwhite(m.name));
        try {
            auto ut = m.unitTest;
            ut();
        }
        catch (Throwable ex) {
            ERROR!"UT failed!"();
            logLine(FG.red("UT failed!"));
            auto seenSep = false;
            foreach(line; ex.toString().lineSplitter()) {
                auto idx = line.indexOf(" ");
                if (seenSep && idx >= 0) {
                    auto loc = line[0 .. idx];
                    auto func = line[idx .. $];
                    writefln("    %-30s  %s", (loc == "??:?") ? "" : loc, func);
                    if (func.startsWith(" int mecca.ut_harness.main")) {
                        break;
                    }
                }
                else {
                    if (!seenSep && line.indexOf("------------") >= 0) {
                        seenSep = true;
                        writeln("    ----------------------------------------------");
                    }
                    else {
                        writeln("    ", line);
                    }
                }
            }
            failed = true;
            break;
        }
    }
    auto endTime = MonoTime.currTime();
    auto secs = (endTime - startTime).total!"msecs" / 1000.0;

    int retVal;
    if (failed) {
        META!"Failed. Ran %s unittests in %.2f seconds"(counter, secs);
        logLine(FG.ired("Failed. Ran %s unittests in %.2f seconds".format(counter, secs)));
        retVal = 1;
    }
    else if (counter == 0) {
        META!"Did not find any unittest to run"();
        logLine(FG.ired("Did not find any unittests to run"));
        retVal = 2;
    }
    else {
        META!"Success. Ran %s unittests in %.2f seconds"(counter, secs);
        logLine(FG.igreen("Success. Ran %s unittests in %.2f seconds".format(counter, secs)));
        retVal = 0;
    }
    DEBUG!"#LOADAVG %s"(cast(immutable char[])read("/proc/loadavg"));

    return retVal;
}

struct mecca_ut {}

void runFixtureTestCases(FIXTURE, string mod = __MODULE__)() {
    import std.stdio;
    import std.traits;
    writeln();
    foreach(testCaseName; __traits(derivedMembers, FIXTURE)) {
        static if ( __traits(compiles, __traits(getMember, FIXTURE, testCaseName) ) ) {
            static if (hasUDA!(__traits(getMember, FIXTURE, testCaseName), mecca_ut)) {
                import std.string:format;
                string fullCaseName = format("%s.%s", __traits(identifier, FIXTURE), testCaseName);
                META!"Test Case: %s"(fullCaseName);
                stderr.writefln("\t%s...", fullCaseName);
                import std.typecons:scoped;
                auto fixture = new FIXTURE();
                try {
                    __traits(getMember, fixture, testCaseName)();
                } catch (Throwable t) {
                    stderr.writeln("\tERROR");
                    throw t;
                }
                destroy(fixture);
                stderr.flush();
            }
        }
    }
}

/**
 * Automatic UT expansion
 *
 * Applying the mixin on a class causes all class members labeled with the @mecca_ut attribute to run.
 */
mixin template TEST_FIXTURE(FIXTURE) {
    unittest {
        runFixtureTestCases!(FIXTURE)();
    }
}

private:
struct FilterLine {
    string filter;
    enum Type { PRECISE, NEGATIVE, PARTIAL }
    Type type;
    bool matched;
}

FilterLine[] filters;
bool listModules;
bool runTests = true;

@notrace void logLine(string text) {
    auto t = Clock.currTime();
    writefln(FG.grey("%02d:%02d:%02d.%03d") ~ " %s", t.hour, t.minute, t.second,
            t.fracSecs.total!"msecs", text);
}

bool shouldRun(string name) {
    if( filters.length==0 )
        return true;

    bool should = false;
    foreach( ref filter; filters ) {
        with(FilterLine.Type) final switch( filter.type ) {
        case PRECISE:
            if( filter.filter == name ) {
                should = true;
                filter.matched = true;
            }
            break;
        case NEGATIVE:
            if( filter.filter == name ) {
                should = false;
            }
            break;
        case PARTIAL:
            if( indexOf(name, filter.filter) != -1 ) {
                should = true;
                filter.matched = true;
            }
        }
    }

    return should;
}

int parseArgs(string[] args) {
    foreach( i, arg; args[1..$] ) {
        if( arg.length==0 ) {
            stderr.writefln("Error: Argument %s has length 0", i);
            return 2;
        }
        switch( arg[0] ) {
        case '=':
            if( arg.length==1 ) {
                stderr.writefln("Error: Argument %s specifies precise match, but does not specify actual match", i);
                return 2;
            }
            filters ~= FilterLine( arg[1..$], FilterLine.Type.PRECISE );
            break;
        case '-':
            if( arg.length==1 ) {
                stderr.writefln("Error: Argument %s specifies negative match, but does not specify actual match", i);
                return 2;
            }
            if( arg[1]=='-' ) {
                if( !parseOption(arg[2..$]) )
                    return 2;
            } else {
                filters ~= FilterLine( arg[1..$], FilterLine.Type.NEGATIVE );
            }
            break;
        default:
            filters ~= FilterLine( arg, FilterLine.Type.PARTIAL );
            break;
        }
    }

    return 0;
}

bool parseOption(string opt) {
    if( opt == "list" ) {
        listModules = true;
        runTests = false;
        return true;
    }

    if( opt == "help" ) {
        writeln(
`UT help: program args
args are a list of filters:
Naked filters are partially matched.
Filters starting with minus ("-") subtract.
Filters starting with equal ("=") match precisely.

Example:
program foo -foo.bar
will run all tests from modules containing "foo" except the module foo.bar

program =foo
will run just the tests in module foo

The filters are processed in order:
program foo -foo.bar hello

will run a module called "foo.bar.hello".

If no filters are given, all modules with unittests are run.

Options:
  --list	list all modules passing the supplied filter
  --help	print this message
`
            );

    runTests = false;

    return true;
}

stderr.writefln("Unknown option \"--%s\"", opt);
return false;
}
