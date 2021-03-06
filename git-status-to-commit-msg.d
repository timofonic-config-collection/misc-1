/**
   Prepare a commit message template based on which files are
   modified. To be used with the git-prepare-commit-msg hook.
*/

module git_prepare_commit_msg;

import std.algorithm;
import std.array;
import std.file;
import std.path;
import std.process;
import std.stdio;
import std.string;

import ae.utils.array;

void main(string[] args)
{
	string prefix = args.length > 1
		? args[1]
		: getcwd.buildNormalizedPath(environment.get("GIT_DIR", ".git")).dirName().baseName() ~ ".";

	string packStaged, packWD;
	while (!stdin.eof)
	{
		auto line = readln().chomp();
		if (line.length > 3)
		{
			void handleLine(string line, ref string pack)
			{
				if (!line.endsWith(".d"))
					return;
				auto mod = line[0..$-2].replace("/", ".");
				if (!mod.skipOver("src."))
					mod = prefix ~ mod;
				if (pack)
					pack = commonPrefix(mod, pack).stripRight('.');
				else
					pack = mod;
			}
			handleLine(line[3..$], line[0].isOneOf("AM") ? packStaged : packWD);
		}
	}
	if (packStaged.length)
		stdout.write(packStaged, ": ");
	else
	if (packWD.length)
		stdout.write(packWD, ": ");
}
