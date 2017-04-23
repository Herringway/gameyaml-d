import std.algorithm;
import std.array;
import std.file;
import std.getopt;
import std.path;
import std.stdio;

import gameyaml;

private struct Problem {
	ulong address;
	string entryname;
	string[] errors;
}
void main(string[] args) {
	bool reverse;
	bool showAllProbs;
	getopt(args,
		"all|a", &showAllProbs,
		"reverse|r", &reverse);
	Problem[][string] problems;
	uint totalproblems = 0;
	uint badEntryCount = 0;
	if (args.length > 1) {
		problems[args[1].baseName] = testFile(args[1], showAllProbs);
	} else {
		foreach (path; dirEntries(".", SpanMode.shallow)) {
			if (path.isDir) {
				if (buildPath(path, path.baseName~".yml").exists) {
					problems[path.baseName] = testFile(buildPath(path, path.baseName~".yml"), showAllProbs);
				}
			}
		}
	}

	foreach (game, problemList; problems) {
		if (problemList.length == 0) {
			continue;
		}
		writeln(game~":\n");
		if (reverse) {
			foreach (prob; problemList.sort!"a.address > b.address") {
				if (prob.errors.length == 0) {
					continue;
				}
				writefln("\t%s:\n\t\t%s", prob.entryname, prob.errors.sort().uniqCount.join("\n\t\t"));
				totalproblems += prob.errors.length;
			}
		} else
			foreach (prob; problemList.sort!"a.address < b.address") {
				if (prob.errors.length == 0) {
					continue;
				}
				writefln("\t%s:\n\t\t%s", prob.entryname, prob.errors.sort().uniqCount.join("\n\t\t"));
				totalproblems += prob.errors.length;
			}
		badEntryCount += problemList.length;
	}
	if (badEntryCount > 0) {
		writefln("Erroneous entries found: %d", badEntryCount);
		writefln("Total errors found: %d", totalproblems);
	} else {
		writeln("No problems found!");
	}
}
Problem[] testFile(string path, bool showAll) {
	Problem[] problems;
	try {
		auto data = loadGameFile(path);
		foreach (entry; data.addresses) {
			if (auto allprobs = entry.problems) {
				if (allprobs.length > 0) {
					problems ~= Problem(
						entry.address,
						entry.name,
						allprobs
							.filter!((x) => showAll ? true : (x.level == IssueLevel.severe))
							.map!((x) => (x.toString))
							.array()
					);
				}
			}
		}
	} catch (Exception e) {
		writefln("Failure loading %s: %s", path, e.msg);
	}
	return problems;
}
string[] uniqCount(T)(T input) {
	import std.string : format;
	string[] output;
	foreach (uniqueString; input.uniq) {
		auto count = input.count(uniqueString);
		if (count > 1) {
			output ~= format("%s (%s)", uniqueString, input.count(uniqueString));
		} else {
			output ~= uniqueString;
		}
	}
	return output;
}