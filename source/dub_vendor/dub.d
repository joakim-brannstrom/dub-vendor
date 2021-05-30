/**
Copyright: Copyright (c) 2021, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Andre Pany
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

Copied from dub-packet-collector and modified.
*/
module dub_vendor.dub;

import logger = std.experimental.logger;
import std.algorithm : filter, each, map;
import std.array : array, appender;
import std.exception : enforce;
import std.json : JSONValue, parseJSON;
import std.process : executeShell, Config;
import std.stdio : writeln;
import std.string : split, join;

import colorlog;
import my.named_type;
import my.path;

shared static this() {
    make!SimpleLogger(logger.LogLevel.info, "dub");
}

alias log = colorlog.log!"dub";

JSONValue getDubDescribeJSON(Path root, NamedType!(string[], Tag!"DubArgs",
        string[].init, TagStringable) args) @safe {
    const cmd = `dub describe --vquiet ` ~ args.get.join(" ");
    const res = executeShell(cmd, null, Config.none, size_t.max, root);

    JSONValue rval;
    try {
        if (res.status == 0) {
            rval = parseJSON(res.output);
        } else {
            log.error("failed to execute dub");
            log.info(cmd);
            log.info(res.output);
        }
    } catch (Exception e) {
        log.info("cannot parse json: ", res.output);
    }

    return rval;
}

alias PacketName = NamedType!(string, Tag!"PacketName", string.init, TagStringable);
alias PacketVersion = NamedType!(string, Tag!"PacketVersion", string.init, TagStringable);

struct DubProject {
    PackageAndPath rootPackage;
    PacketName[] linkedDependencies;
    PackageAndPath[PacketName] dependencies;
}

struct PackageAndPath {
    PacketName name;
    PacketVersion version_;
    AbsolutePath path;
}

string mainPackageName(string packageName) {
    return packageName.split(":")[0];
}

DubProject toDubProject(JSONValue dubDescribe) {
    auto rootPackage = typeof(PackageAndPath.name)(dubDescribe["rootPackage"].str);

    string[] linkDependencies = dubDescribe["targets"].array.filter!(
            js => js["rootPackage"].str == rootPackage.get).array[0]
        .object["linkDependencies"].array.map!(js => js.str).array;

    PackageAndPath[PacketName] packs = () {
        PackageAndPath[PacketName] rval;
        foreach (js; dubDescribe["packages"].array)
            rval[PacketName(js["name"].str)] = PackageAndPath(PacketName(js["name"].str),
                    PacketVersion(js["version"].str), AbsolutePath(js["path"].str));
        return rval;
    }();

    auto root = PackageAndPath(rootPackage, PacketVersion("*"), AbsolutePath("."));
    return DubProject(root, linkDependencies.map!(name => PacketName(name)).array, packs);
}
