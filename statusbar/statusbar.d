/**
   An efficient i3bar data source.
*/

module statusbar;

import std.algorithm.iteration;
import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import std.exception;
import std.file;
import std.functional;
import std.path;
import std.stdio;
import std.string;
import std.process;

import ae.net.asockets;
import ae.sys.file;
import ae.sys.inotify;
import ae.sys.timing;
import ae.utils.array;
import ae.utils.graphics.color;
import ae.utils.meta;
import ae.utils.meta.args;
import ae.utils.path;
import ae.utils.time.format;

import fontawesome;
import i3;
import i3conn;
import mpd;
import pulse;

I3Connection conn;

enum iconWidth = 11;

class Block
{
private:
	static BarBlock*[] blocks;
	static Block[] blockOwners;
	string lastNotificationID = null;

protected:
	final void addBlock(BarBlock* block)
	{
		block.instance = text(blocks.length);
		blocks ~= block;
		blockOwners ~= this;
	}

	static void send()
	{
		conn.send(blocks);
	}

	void handleClick(BarClick click)
	{
	}

	void showNotification(string str, string hints = null)
	{
		string[] commandLine = ["dunstify", "-t", "1000", "--printid", str];
		if (hints)
			commandLine ~= "--hints=" ~ hints;
		if (lastNotificationID)
			commandLine ~= "--replace=" ~ text(lastNotificationID);
		auto result = execute(commandLine);
		lastNotificationID = result.output.strip();
	}

public:
	static void clickHandler(BarClick click)
	{
		try
		{
			auto n = click.instance.to!size_t;
			enforce(n < blockOwners.length);
			blockOwners[n].handleClick(click);
		}
		catch (Throwable e)
			spawnProcess(["notify-send", e.msg]).wait();
	}
}

class TimerBlock : Block
{
	abstract void update(SysTime now);

	this()
	{
		if (!instances.length)
			onTimer();
		instances ~= this;
		update(Clock.currTime());
	}

	static TimerBlock[] instances;

	static void onTimer()
	{
		auto now = Clock.currTime();
		setTimeout(toDelegate(&onTimer), 1.seconds - now.fracSecs);
		foreach (instance; instances)
			instance.update(now);
		send();
	}
}

class TimeBlock(string timeFormat) : TimerBlock
{
	BarBlock block;
	immutable(TimeZone) tz;

	static immutable iconStr = text(wchar(FontAwesome.fa_clock_o)) ~ "  ";

	this(immutable(TimeZone) tz)
	{
		this.tz = tz;
		addBlock(&block);
	}

	override void update(SysTime now)
	{
		auto local = now;
		local.timezone = tz;
		block.full_text = iconStr ~ local.formatTime!timeFormat;
		block.background = '#' ~ timeColor(local).toHex();
	}

	static RGB timeColor(SysTime time)
	{
		enum day = 1.days.total!"seconds";
		time += time.utcOffset;
		auto unixTime = time.toUnixTime;
		int tod = unixTime % day;

		enum l = 0x40;
		enum L = l*3/2;

		static immutable RGB[] colors =
			[
				RGB(0, 0, L),
				RGB(0, l, l),
				RGB(0, L, 0),
				RGB(l, l, 0),
				RGB(L, 0, 0),
				RGB(l, 0, l),
			];
		alias G = Gradient!(int, RGB);
		import std.range : iota;
		import std.array : array;
		static immutable grad = G((colors.length+1).iota.map!(n => G.Point(cast(int)(day / colors.length * n), colors[n % $])).array);

		return grad.get(tod);
	}

	override void handleClick(BarClick click)
	{
		if (click.button == 1)
			spawnProcess(["t", "sh", "-c", "cal -y ; read -n 1"]).wait();
	}
}

class UtcTimeBlock : TimeBlock!`D Y-m-d H:i:s \U\T\C`
{
	this() { super(UTC()); }
}

alias TzTimeBlock = TimeBlock!`D Y-m-d H:i:s O`;

final class LoadBlock : TimerBlock
{
	BarBlock icon, block;

	this()
	{
		icon.full_text = text(wchar(FontAwesome.fa_tasks));
		icon.min_width = iconWidth;
		icon.separator = false;
		addBlock(&icon);
		addBlock(&block);
	}

	override void update(SysTime now)
	{
		block.full_text = readText("/proc/loadavg").splitter(" ").front;
	}

	override void handleClick(BarClick click)
	{
		if (click.button == 1)
			spawnProcess(["t", "htop"]).wait();
	}
}

final class PulseBlock : Block
{
	BarBlock icon, block;
	string sinkName;
	Volume oldValue;

	this(string sinkName)
	{
		this.sinkName = sinkName;

		icon.min_width = iconWidth;
		icon.separator = false;
		icon.name = "icon";

		block.min_width_str = "100%";
		block.alignment = "right";

		addBlock(&icon);
		addBlock(&block);

		pulseSubscribe(&update);
		update();
	}

	void update()
	{
		auto volume = getVolume(sinkName);
		if (oldValue == volume)
			return;
		oldValue = volume;

		wchar iconChar = FontAwesome.fa_volume_off;
		string volumeStr = "???%";
		if (volume.known)
		{
			auto n = volume.percent;
			iconChar =
				volume.muted ? FontAwesome.fa_volume_off :
				n == 0 ? FontAwesome.fa_volume_off :
				n < 50 ? FontAwesome.fa_volume_down :
				         FontAwesome.fa_volume_up;
			volumeStr = "%3d%%".format(volume.percent);
		}

		icon.full_text = text(iconChar);
		icon.color = volume.muted ? "#ff0000" : null;
		block.full_text = volumeStr;
		block.color = volume.percent > 100 ? "#ff0000" : null;

		send();

		showNotification("Volume: " ~
			(!volume.known
				? "???"
				: "[%3d%%]%s".format(
					volume.percent,
					volume.muted ? " [Mute]" : ""
				)),
			volume.percent > 100 ? "string:fgcolor:#ff0000" : null);
	}

	override void handleClick(BarClick click)
	{
		if (click.button == 1)
			if (click.name == "icon")
				spawnProcess(["pactl", "set-sink-mute", sinkName, "toggle"]).wait();
			else
				spawnProcess(["x", "pavucontrol"]).wait();
		else
		if (click.button == 3)
			spawnProcess(["speakers"], stdin, File(nullFileName, "w")).wait();
		else
		if (click.button == 4)
			spawnProcess(["pactl", "set-sink-volume", sinkName, "+5%"]).wait();
		else
		if (click.button == 5)
			spawnProcess(["pactl", "set-sink-volume", sinkName, "-5%"]).wait();
	}
}

final class MpdBlock : Block
{
	BarBlock icon, block;
	string status;

	this()
	{
		icon.min_width = iconWidth;
		icon.name = "icon";

		addBlock(&icon);
		addBlock(&block);
		mpdSubscribe(&update);
		update();
	}

	void update()
	{
		auto status = getMpdStatus();
		this.status = status.status;
		wchar iconChar;
		switch (status.status)
		{
			case "playing":
				iconChar = FontAwesome.fa_play;
				break;
			case "paused":
				iconChar = FontAwesome.fa_pause;
				break;
			case null:
				iconChar = FontAwesome.fa_stop;
				break;
			default:
				iconChar = FontAwesome.fa_music;
				break;
		}

		icon.full_text = text(iconChar);
		block.full_text = status.nowPlaying;
		icon.separator = status.nowPlaying.length == 0;
		send();
	}

	override void handleClick(BarClick click)
	{
		if (click.name == "icon")
		{
			if (click.button == 1)
			{
				string cmd;
				if (status == "playing")
					cmd = click.button == 1 ? "pause" : "stop";
				else
					cmd = "play";
				spawnProcess(["mpc", cmd], stdin, File("/dev/null", "wb")).wait();
			}
			else
				spawnProcess(["x", "cantata"]).wait();
		}
		else
			if (click.button == 1)
				spawnProcess(["x", "cantata"]).wait();
	}
}

class ProcessBlock : Block
{
	BarBlock block;
	void delegate(BarClick) clickHandler;

	this(string[] args, void delegate(BarClick) clickHandler = null)
	{
		this.clickHandler = clickHandler;

		import core.sys.posix.unistd;
		auto p = pipeProcess(args, Redirect.stdout);
		auto sock = new FileConnection(p.stdout.fileno.dup);
		auto lines = new LineBufferedAdapter(sock);
		lines.delimiter = "\n";

		lines.handleReadData =
			(Data data)
			{
				auto line = cast(char[])data.contents;
				block.full_text = line.idup;
				send();
			};

		addBlock(&block);
	}

	override void handleClick(BarClick click)
	{
		if (clickHandler)
			clickHandler(click);
	}
}

final class BrightnessBlock : Block
{
	BarBlock icon, block;
	int oldValue = -1;

	this()
	{
		icon.full_text = text(wchar(FontAwesome.fa_sun_o));
		icon.min_width = iconWidth;
		icon.separator = false;

		addBlock(&icon);
		addBlock(&block);
		update();

		enum fn = "/tmp/brightness";
		if (!fn.exists)
			fn.touch();
		iNotify.add(fn, INotify.Mask.create | INotify.Mask.modify,
			(in char[] name, INotify.Mask mask, uint cookie)
			{
				update();
			}
		);
	}

	void update()
	{
		auto result = execute(["/home/vladimir/bin/brightness-get"]);
		try
		{
			enforce(result.status == 0);
			auto value = result.output.strip().to!int;
			if (oldValue == value)
				return;
			oldValue = value;

			block.full_text = format("%3d%%", value);
			send();

			showNotification("Brightness: [%3d%%]".format(value));
		}
		catch (Exception) {}
	}

	override void handleClick(BarClick click)
	{
		if (click.button == 4)
			spawnProcess(["/home/vladimir/bin/brightness-up"]).wait();
		else
		if (click.button == 5)
			spawnProcess(["/home/vladimir/bin/brightness-down"]).wait();
	}
}

final class BatteryBlock : Block
{
	BarBlock icon, block;
	string devicePath;
	SysTime lastUpdate;

	this(string deviceMask)
	{
		auto devices = execute(["upower", "-e"])
			.output
			.splitLines
			.filter!(line => globMatch(line, deviceMask))
			.array;
		this.devicePath = devices.length ? devices[0] : null;

		icon.min_width = 17;
		icon.alignment = "center";
		icon.separator = false;
		icon.name = "icon";

		addBlock(&icon);
		addBlock(&block);

		import core.sys.posix.unistd;
		auto p = pipeProcess(["upower", "--monitor"], Redirect.stdout);
		auto sock = new FileConnection(p.stdout.fileno.dup);
		auto lines = new LineBufferedAdapter(sock);
		lines.delimiter = "\n";

		lines.handleReadData =
			(Data data)
			{
				auto now = Clock.currTime();
				if (now - lastUpdate >= 1.msecs)
				{
					lastUpdate = now;
					update();
				}
			};
	}

	void update()
	{
		wchar iconChar = FontAwesome.fa_question_circle;
		string blockText, color;

		try
		{
			enforce(devicePath, "No device");
			auto result = execute(["upower", "-i", devicePath]);
			enforce(result.status == 0, "upower failed");

			string[string] props;
			foreach (line; result.output.splitLines())
			{
				auto parts = line.findSplit(":");
				if (!parts[1].length)
					continue;
				props[parts[0].strip] = parts[2].strip;
			}

			auto percentage = props.get("percentage", "0%").chomp("%").to!int;

			switch (props.get("state", ""))
			{
				case "charging":
					iconChar = FontAwesome.fa_bolt;
					break;
				case "fully-charged":
					iconChar = FontAwesome.fa_plug;
					break;
				case "discharging":
					switch (percentage)
					{
						case  0: .. case  20: iconChar = FontAwesome.fa_battery_empty         ; break;
						case 21: .. case  40: iconChar = FontAwesome.fa_battery_quarter       ; break;
						case 41: .. case  60: iconChar = FontAwesome.fa_battery_half          ; break;
						case 61: .. case  80: iconChar = FontAwesome.fa_battery_three_quarters; break;
						case 81: .. case 100: iconChar = FontAwesome.fa_battery_full          ; break;
						default: iconChar = FontAwesome.fa_question_circle; break;
					}

					alias G = Gradient!(int, RGB);
					static immutable grad = G([
						G.Point(10, RGB(255,   0,   0)), // red
						G.Point(30, RGB(255, 255,   0)), // yellow
						G.Point(50, RGB(255, 255, 255)), // white
					]);
					color = '#' ~ grad.get(percentage).toHex();

					break;
				default:
					iconChar = FontAwesome.fa_question_circle;
					break;
			}

			blockText = props.get("percentage", "???");
		}
		catch (Exception e)
			stderr.writeln(e.msg);

		icon.full_text = text(iconChar);
		block.full_text = blockText;
		block.color = color;
		send();
	}

	override void handleClick(BarClick click)
	{
		// if (click.button == 1)
		// 	spawnProcess(["t", "powertop"]).wait();
	}
}

void main()
{
	conn = new I3Connection();
	conn.clickHandler = toDelegate(&Block.clickHandler);

	try
	{
		// System log
		//new ProcessBlock(["journalctl", "--follow"]);

		// Current window title
		new ProcessBlock(["xtitle", "-s"], (click) {
				switch (click.button)
				{
					case 1: spawnProcess(["x", "rofi", "-show", "window"]).wait(); break;
					case 4: spawnProcess(["i3-msg", "workspace", "prev_on_output"], stdin, File(nullFileName, "w")).wait(); break;
					case 5: spawnProcess(["i3-msg", "workspace", "next_on_output"], stdin, File(nullFileName, "w")).wait(); break;
					default: break;
				}
			});

		// Current playing track
		new MpdBlock();

		// Volume
		version (HOST_vaio)
			new PulseBlock("alsa_output.pci-0000_00_1b.0.analog-stereo");
		else
			new PulseBlock("combined");

		// Brightness
		new BrightnessBlock();

		// Battery
		version (HOST_vaio)
			new BatteryBlock("/org/freedesktop/UPower/devices/battery_BAT1");
		version (HOST_home)
			new BatteryBlock("/org/freedesktop/UPower/devices/ups_hiddev*");

		// Load
		new LoadBlock();

		// UTC time
		new UtcTimeBlock();

		// Local time
		string timeZone;
		try
			timeZone = readText(expandTilde("~/.config/tz").strip());
		catch (FileException)
			timeZone = "Europe/Chisinau";
		new TzTimeBlock(PosixTimeZone.getTimeZone(timeZone));

		socketManager.loop();
	}
	catch (Throwable e)
	{
		std.file.write("statusbar-error.txt", e.toString());
		throw e;
	}
}
