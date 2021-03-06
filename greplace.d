/**
   Replace a raw string in the given files and file names.

   By default, ensures that the operation is undoable, i.e. aborts if
   the new string is already found in any of the files.
*/

module greplace;

import std.algorithm;
import std.array;
import std.conv;
import std.file;
import std.getopt;
import std.path;
import std.range;
import std.stdio;
import std.string;

void main(string[] args)
{
	bool force, wide, noContent;
	getopt(args,
		"w|wide", &wide,
		"f|force", &force,
		"no-content", &noContent,
	);

	if (args.length < 3)
		throw new Exception("Usage: " ~ args[0] ~ " [-f] <from> <to> [TARGETS...]");
	auto targets = args[3..$];
	if (!targets.length)
		targets = [""];

	ubyte[] from, to, fromw, tow;
	from = cast(ubyte[])args[1];
	to   = cast(ubyte[])args[2];

	if (wide)
	{
		fromw = cast(ubyte[])std.conv.to!wstring(args[1]);
		tow   = cast(ubyte[])std.conv.to!wstring(args[2]);
	}

	auto files = targets.map!(target => target.empty || target.isDir ? dirEntries(target, SpanMode.breadth).map!`a.name`().array : [target]).join();
	if (!force)
	{
		foreach (file; files)
		{
			ubyte[] data;
			if (file.isSymlink())
				data = cast(ubyte[])readLink(file);
			else
			if (file.isFile())
				data = cast(ubyte[])std.file.read(file);
			else
				continue;

			if (!noContent)
			{
				if (data.countUntil(to)>=0)
					throw new Exception("File " ~ file ~ " already contains " ~ args[2]);
				if (wide && data.countUntil(tow)>=0)
					throw new Exception("File " ~ file ~ " already contains " ~ args[2] ~ " (in UTF-16)");
			}
		}
	}

	foreach (file; files)
	{
		if (!noContent)
		{
			ubyte[] s;
			if (file.isSymlink())
				s = cast(ubyte[])readLink(file);
			else
			if (file.isFile())
				s = cast(ubyte[])std.file.read(file);
			else
				continue;

			bool modified = false;
			if (s.countUntil(from)>=0)
			{
				s = s.replace(from, to);
				modified = true;
			}
			if (wide && s.countUntil(fromw)>=0)
			{
				s = s.replace(fromw, tow);
				modified = true;
			}

			if (modified)
			{
				writeln(file);

				if (file.isFile())
					std.file.write(file, s);
				else
				if (file.isSymlink())
				{
					remove(file);
					symlink(cast(string)s, file);
				}
				else
					assert(false);
			}
		}

		if (file.indexOf(args[1])>=0)
		{
			string newName = file.replace(args[1], args[2]);
			writeln(file, " -> ", newName);
	
			if (!exists(dirName(newName)))
				mkdirRecurse(dirName(newName));
			std.file.rename(file, newName);
	
			// TODO: empty folders

			auto segments = array(pathSplitter(file))[0..$-1];
			foreach_reverse (i; 0..segments.length)
			{
				auto dir = buildPath(segments[0..i+1]);
				if (array(map!`a.name`(dirEntries(dir, SpanMode.shallow))).length==0)
					rmdir(dir);
			}	
		}
	}
}
