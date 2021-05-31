/**
Copyright: Copyright (c) 2019, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module app;

import logger = std.experimental.logger;
import std.algorithm : joiner;

import colorlog;
import my.named_type;
import my.path;

int main(string[] args) {
    confLogger(VerboseMode.info);

    auto conf = parseUserArgs(args);
    if (conf.global.helpInfo.helpWanted) {
        return cli(conf);
    }

    try {
        confLogger(conf.global.verbosity);
        setLogLevel(conf.global.loggLvls);
    } catch (Exception e) {
        logger.info("Loggers ", getRegisteredLoggers);
        return cli(conf);
    }

    import std.variant : visit;

    // dfmt off
    return conf.data.visit!(
          (Config.Help a) => cli(conf),
          (Config.Init a) => cli(a),
    );
    // dfmt on
}

private:

shared static this() {
    make!SimpleLogger(logger.LogLevel.info, "app");
}

alias log = colorlog.log!"app";

int cli(Config conf) {
    conf.printHelp;
    return 0;
}

int cli(Config.Init conf) {
    import std.process : spawnProcess, wait;
    import dub_vendor.dub;
    import my.set;
    import std.file : mkdirRecurse;

    auto dub = getDubDescribeJSON(Path("."), conf.dubArgs).toDubProject;
    log.trace(dub);

    auto rsyncCmd = [
        "rsync", "-va", "--exclude=.dub", "--exclude=.git", "--exclude=*.a",
        "--exclude=build"
    ];
    if (conf.deleteDst.get)
        rsyncCmd ~= "--delete";

    mkdirRecurse("vendor");

    Set!string copied;
    copied.add(dub.rootPackage.name.get);
    foreach (dep; dub.dependencies.byValue) {
        if (dep.name.get !in copied) {
            const dst = Path("vendor") ~ dep.name.get;
            log.infof("copy %s -> %s", dep.path, dst);
            if (spawnProcess(rsyncCmd ~ [dep.path.toString ~ "/", dst.toString]).wait != 0) {
                log.warning("Failed to copy ", dep.name.get);
                log.info(rsyncCmd.joiner(" "));
            }
        }

        copied.add(dep.name.get);
    }

    return 0;
}

struct Config {
    import std.variant : Algebraic, visit;
    static import std.getopt;

    static struct Global {
        std.getopt.GetoptResult helpInfo;
        VerboseMode verbosity;
        bool help = true;
        string progName;
        NameLevel[] loggLvls;
    }

    static struct Help {
        std.getopt.GetoptResult helpInfo;
    }

    static struct Init {
        std.getopt.GetoptResult helpInfo;
        static string helpDescription = "initial vendoring of dependencies";
        NamedType!(string[], Tag!"DubArgs", string[].init, TagStringable) dubArgs;
        NamedType!(bool, Tag!"RsyncUseDelete", bool.init, TagStringable) deleteDst;
    }

    alias Type = Algebraic!(Help, Init);
    Type data;

    Global global;

    void printHelp() {
        import std.algorithm : filter, map, maxElement;
        import std.array : array;
        import std.format : format;
        import std.getopt : defaultGetoptPrinter;
        import std.meta : AliasSeq;
        import std.stdio : writeln, writefln;
        import std.string : toLower;
        import std.traits : hasMember;

        static void printGroup(T)(std.getopt.GetoptResult global,
                std.getopt.GetoptResult helpInfo, string progName) {
            const helpDescription = () {
                static if (hasMember!(T, "helpDescription"))
                    return T.helpDescription ~ "\n";
                else
                    return null;
            }();
            defaultGetoptPrinter(format("usage: %s %s <options>\n%s", progName,
                    T.stringof.toLower, helpDescription), global.options);
            defaultGetoptPrinter(null, helpInfo.options.filter!(a => a.optShort != "-h").array);
        }

        static void printHelpGroup(T)(std.getopt.GetoptResult helpInfo, string progName) {
            defaultGetoptPrinter(format("usage: %s <command>\n", progName), helpInfo.options);
            writeln("sub-commands");
            string[2][] subCommands;
            static foreach (T; Type.AllowedTypes) {
                static if (hasMember!(T, "helpDescription"))
                    subCommands ~= [T.stringof.toLower, T.helpDescription];
                else
                    subCommands ~= [T.stringof.toLower, null];
            }
            const width = subCommands.map!(a => a[0].length).maxElement + 1;
            foreach (cmd; subCommands)
                writefln(" %s%*s %s", cmd[0], width - cmd[0].length, " ", cmd[1]);
        }

        template printers(T...) {
            static if (T.length == 1) {
                static if (is(T[0] == Config.Help))
                    alias printers = (T[0] a) => printHelpGroup!(T[0])(global.helpInfo,
                            global.progName);
                else
                    alias printers = (T[0] a) => printGroup!(T[0])(global.helpInfo,
                            a.helpInfo, global.progName);
            } else {
                alias printers = AliasSeq!(printers!(T[0]), printers!(T[1 .. $]));
            }
        }

        data.visit!(printers!(Type.AllowedTypes));
    }
}

Config parseUserArgs(string[] args) {
    import logger = std.experimental.logger;
    import std.algorithm : remove;
    import std.format : format;
    import std.path : baseName, buildPath;
    import std.string : toLower;
    import std.traits : EnumMembers;
    static import std.getopt;

    Config conf;
    conf.data = Config.Help.init;
    conf.global.progName = args[0].baseName;

    string group;
    if (args.length > 1 && args[1][0] != '-') {
        group = args[1];
        args = args.remove(1);
    }

    try {
        void globalParse() {
            Config.Help data;
            string rawLoggLvls;

            scope (success)
                conf.data = data;
            // dfmt off
            conf.global.helpInfo = std.getopt.getopt(args, std.getopt.config.passThrough,
                "verbose-mode", "Set the verbosity of a logger, name=level comma separated", &rawLoggLvls,
                "v|verbose", format("Set the verbosity (%-(%s, %))", [EnumMembers!(VerboseMode)]), &conf.global.verbosity,
                );
            // dfmt on
            if (conf.global.helpInfo.helpWanted)
                args ~= "-h";

            try {
                conf.global.loggLvls = parseLogNames(rawLoggLvls);
            } catch (Exception e) {
            }
        }

        void helpParse() {
            conf.data = Config.Help.init;
        }

        void initParse() {
            Config.Init data;
            scope (success)
                conf.data = data;

            // dfmt off
            data.helpInfo = std.getopt.getopt(args,
                "delete", "delete files in vendor that has been removed in src", data.deleteDst.getPtr,
                "dub-arg", "extra argument for dub", data.dubArgs.getPtr,
                );
            // dfmt on
        }

        alias ParseFn = void delegate();
        ParseFn[string] parsers;

        static foreach (T; Config.Type.AllowedTypes) {
            mixin(format(`parsers["%1$s"] = &%1$sParse;`, T.stringof.toLower));
        }

        globalParse;

        if (auto p = group in parsers) {
            (*p)();
        }
    } catch (std.getopt.GetOptException e) {
        // unknown option
        logger.error(e.msg);
    } catch (Exception e) {
        logger.error(e.msg);
    }

    return conf;
}
