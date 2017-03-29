/++
+ Module supporting game.yml manipulation. Can read and write game.yml files,
+ as well as read and write data from associated games.
+/
module gameyaml.gamedata;

import std.algorithm;
import std.bigint;
import std.bitmanip;
import std.conv;
import std.datetime;
import std.encoding;
import std.exception;
import std.file;
import std.format;
import std.outbuffer;
import std.range;
import std.stdio;
import std.string;
import std.system;
import std.typecons;
import std.uni;
import std.variant;

import wyaml;
import libdmathexpr.mathexpr;

/++
+ Struct representing all information in a game.yml file.
+/
struct GameData {
	///CPU information
	struct CPUDetails {
		///The architecture the cpu implements
		string architecture;
		///Various settings for the CPU
		string[string] settings;
	}
	///Processor information
	CPUDetails processor;
	///Script table definitions
	ScriptTable[string] scriptTables;
	///Title of the game
	string title;
	///Country the game was released in
	string country;
	///Default script format
	string defaultScript;
	///SHA-1 hash of the game
	string hash;
	///Address definitions for the game
	GameStruct[string] addresses;
	string toString() {
		string[] output;
		output ~= format("Game: %s (%s)", title, country);
		output ~= format("CPU: %s", processor.architecture);
		if (defaultScript != defaultScript.init) {
			output ~= format("Default Script Format: %s", defaultScript);
		}
		output ~= format("%(%s, %)", addresses.keys);
		return output.join("\n\t");
	}
}
/++
+ Script table information. Represents a variable-length byte
+ sequence<->string mapping.
+/
struct ScriptTable {
	///Sequences following this one
	ScriptTable[ubyte] subtables;
	///String to replace a byte sequence with
	Nullable!string stringReplacement;
	///Number of bytes making up this sequence. May be a math expression.
	string length = "1";
	/++
	+ Calculates the actual length of the byte sequence. May not be accurate
	+ until a terminating entry is reached.
	+/
	int realLength(const ubyte[] vals) const {
		real[string] vars;
		foreach (i, value; vals) {
			vars[format("ARG_%02d", i)] = value;
		}
		return parseMathExpr(length).evaluate(vars).to!int;
	}
	/++
	+ Whether or not this entry represents a terminating byte in the sequence
	+ with the next byte given.
	+/
	bool terminates(const ubyte nextVal) const {
		if (subtables.length == 0) {
			return true;
		}
		if (nextVal !in subtables) {
			return true;
		}
		return false;
	}
	/++
	+ Convert a string to a byte array.
	+ Bugs: Currently unimplemented.
	+/
	ubyte[] reverse(const string) const {
		assert(0);
	}
	/++
	+ Convert a byte array to a string according to the loaded rules.
	+/
	string replaceStr(const ubyte[] bytes) const {
		string output;
		for (int i = 0; i < bytes.length; i++) {
			auto start = i;
			if (bytes[i] in subtables) {
				auto table = cast()subtables.dup[bytes[i]];
				while (!table.terminates(bytes[i])) {
					if (table.realLength(bytes[start..i+1]) <= i-start) {
						break;
					}
					i++;
					table = table.subtables[bytes[i]];
				}
				if (!table.stringReplacement.isNull) {
					output ~= table.stringReplacement;
				} else {
					output ~= format("[%(%02X %)]", bytes[start..i+1]);
				}
			} else {
				output ~= format("[%02X]", bytes[i]);
			}
		}
		return output;
	}
}
///Types that can be stored in the game.yml address entries
enum EntryType {
	///Simple numbers
	integer,
	///Variable-length byte sequences
	script,
	///Arrays of some other type
	array,
	///Pointer to some other data
	pointer,
	///A structure grouping related values together
	struct_,
	///Bytes split into sub-byte-sized types
	bitField,
	///A unit of graphical data
	tile,
	///Assembly code for the game system's CPU to run
	assembly,
	///Nothing
	null_,
	///Colour data, often paired with tiles
	color,
	///Unknown data
	undefined
}
/++
+ Definition for a contiguous chunk of data in the game.
+/
struct GameStruct {
	int opCmp(ref const GameStruct b) const {
		if (address != b.address) {
			return cast(int) (address-b.address);
		} else if (name != b.name) {
			return cmp(name,b.name);
		} else if (description != b.description) {
			return cmp(description,b.description);
		} else if (notes != b.notes) {
			return cmp(notes,b.notes);
		} else if (type != b.type) {
			return cast(int) (type-b.type);
		} else if (size != b.size) {
			return cmp(size, b.size);
		}
		return 0;
	}
	bool opEquals(const ref GameStruct b) const {
		return this.opCmp(b) == 0;
	}
	size_t toHash() const nothrow {
		size_t hash = address.hashOf;
		hash = name.hashOf(hash);
		hash = description.hashOf(hash);
		hash = notes.hashOf(hash);
		hash = type.hashOf(hash);
		hash = size.hashOf(hash);
		return hash;
	}
	///Name of this data. Must be unique.
	string name;
	///Prettier name for this data. Does not need to be unique.
	string prettyName;
	///Simple description of the data's purpose.
	string description;
	///Miscellaneous notes, magic numbers, etc.
	string notes;
	///Scripts - Character set to use.
	string charSet;
	///Integers - Number base (binary, decimal, hexadecimal...)
	ubyte numberBase;
	///Pointers - Base address (pointerBase + [value])
	ulong pointerBase;
	///Type of data represented.
	EntryType type;
	///Integers - Endianness to use. Default depends on architecture.
	Endian endianness;
	///Address of the data represented. Does not exist in subentries (e.g. structs, arrays).
	Nullable!ulong address;
	///Integers - Whether or not the value is signed.
	bool isSigned;
	///Tiles - Format to use for representing this tile. Default depends on architecture.
	string format;
	///Size of data. May be a math expression. May not be set if terminator is used.
	string size;
	///Name of a data table associated with this data.
	string references;
	///Integers - Indicates that val & (1<<index) has a special value.
	string[] bitValues;
	///Byte sequence indicating the end of this data.
	ubyte[] terminator;
	///Assembly, Arrays - Human-readable labels for specified offsets.
	string[ulong] labels;
	///Assembly - Human-readable names for routine-local variables.
	string[ulong] localVariables;
	///Integers - Mapping of integer values to magic values.
	string[ulong] values;
	///Assembly - Specifies the final results for registers and memory addresses post-execution.
	string[string] returnValues;
	///Assembly - Specifies the meanings of registers and memory addresses pre-execution.
	string[string] arguments;
	///Assembly - Initial CPU state on entering this code.
	string[string] initialState;
	///Assembly - Final CPU state after executing this code.
	string[string] finalState;
	///Assembly - CPU state after reaching specified labels.
	string[string][string] labelStates;
	///Structs - Definitions for chunks of data within this chunk.
	GameStruct[] subEntries;
	///Arrays - Definition of the chunk of data repeated within this chunk.
	auto ref itemType() {
		if (subEntries.length == 0) {
			subEntries ~= GameStruct();
		}
		return subEntries[0];
	}
	///Issues encountered while reading this entry. Use .problems() for subentries.
	GameStructIssue[] entryProblems;
	///Memory space this entry exists in. Typically only one such space exists.
	size_t memorySpaceID;
	///Whether or not the size of this data is known ahead of time.
	bool sizeKnown() {
		if (size == "") {
			return false;
		}
		return true;
	}
	/++
	+ The real size of this data structure, if it can be calculated.
	+ Params:
	+   vars = Other integers parsed before reading this entry. Used in math expression-ized size entries.
	+ Throws: BadSizeException if a size cannot be calculated.
	+ Returns: Size of the data structure.
	+/
	ulong realSize(real[string] vars = null) {
		if (!sizeKnown) {
			throw new BadSizeException();
		}
		try {
			return parseMathExpr(size).evaluate(vars).to!ulong();
		} catch (Exception) {
			throw new BadSizeException(size);
		}
	}
	///Problems in entry detected while parsing the .yml file.
	GameStructIssue[] problems() {
		GameStructIssue[] recurseSubEntries(GameStruct entry) {
			GameStructIssue[] issues;
			foreach (subentry; entry.subEntries) {
				issues ~= recurseSubEntries(subentry);
			}
			if (!entry.type == EntryType.array) {
				issues ~= recurseSubEntries(entry.itemType);
			}
			issues ~= entry.entryProblems;
			return issues;
		}
		return recurseSubEntries(this);
	}
	///Short string representation of this entry.
	string toString() const {
		return std.format.format("%s: %s,%s", name, address, size);
	}
}
/++
+ GameStruct issue severity level.
+/
enum IssueLevel {
	///Issue is severe. Cannot correctly parse this entry.
	severe,
	///Indicates entry is incomplete. Non-fatal.
	incomplete
}
/++
+ Information on GameStruct issues. Includes reason, potential fixes,
+ and severity level.
+/
struct GameStructIssue {
	///Information on the problem encountered.
	string reason;
	///Potential fixes to be implemented.
	string fix;
	///Severity level.
	IssueLevel level;
	string toString() const {
		return reason ~ " (" ~ fix ~ ")";
	}
}
alias constructAssemblyBlock = constructBlock!(EntryType.assembly);
alias constructEmptyBlock = constructBlock!(EntryType.null_);
alias constructStructBlock = constructBlock!(EntryType.struct_);
alias constructIntBlock = constructBlock!(EntryType.integer);
alias constructScriptBlock = constructBlock!(EntryType.script);
alias constructPointerBlock = constructBlock!(EntryType.pointer);
alias constructArrayBlock = constructBlock!(EntryType.array);
alias constructBitfieldBlock = constructBlock!(EntryType.bitField);
alias constructUnknownBlock = constructBlock!(EntryType.undefined);
alias constructTileBlock = constructBlock!(EntryType.tile);
alias constructColorBlock = constructBlock!(EntryType.color);
alias constructDataBlock = constructBlock!(EntryType.undefined);


///Game.yml 1.0 types. Obsoleted by 2.0's tags.
private enum YAML10Types {
	int_ = "int",
	hexint = "hexint",
	script = "script",
	pointer = "pointer",
	bytearray = "bytearray",
	struct_ = "struct",
	table = "table",
	bitstruct = "bitstruct",
	bitfield = "bitfield",
	palette = "palette",
	tile = "tile",
	empty = "empty",
	nullspace = "nullspace",
	data = "data",
	assembly = "assembly"
}

/++
+ Parses a game.yml v1.0 entry. This is a fairly awkward translation and should
+ not be relied on for automatic upgrading.
+/
private GameStruct constructOldBlock(ref Node node) {
	GameStruct block;
	if ("Type" in node) {
		final switch (cast(YAML10Types)node["Type"]) {
			case YAML10Types.int_ ,YAML10Types.hexint:
				block = constructIntBlock(node);
				break;
			case YAML10Types.script:
				block = constructScriptBlock(node);
				break;
			case YAML10Types.pointer:
				block = constructPointerBlock(node);
				break;
			case YAML10Types.bytearray:
				block = constructArrayBlock(node);
				block.itemType = GameStruct();
				break;
			case YAML10Types.struct_, YAML10Types.table, YAML10Types.bitstruct:
				block = constructStructBlock(node);
				break;
			case YAML10Types.bitfield:
				block = constructBitfieldBlock(node);
				break;
			case YAML10Types.palette:
				block = constructArrayBlock(node);
				break;
			case YAML10Types.tile:
				block = constructTileBlock(node);
				break;
			case YAML10Types.empty, YAML10Types.nullspace:
				block = constructEmptyBlock(node);
				break;
			case YAML10Types.data:
				block = constructDataBlock(node);
				break;
			case YAML10Types.assembly:
				block = constructAssemblyBlock(node);
				break;
		}
		block.entryProblems ~= GameStructIssue("Old entry type used", "Switch to type tag");
	} else {
		block = constructIntBlock(node);
		block.entryProblems ~= GameStructIssue("Implied int type is deprecated", "Use !int tag");
	}
	return block;
}
/++
+ Parser encountered a deprecated key. Usually has a replacement, but this is
+ not guaranteed to be true in the future.
+/
private void deprecatedKey(ref Node node, ref GameStruct structure, string key, string keyOld = "") {
	if (keyOld == "") {
		keyOld = key.toLower();
	}
	if (keyOld in node) {
		node[key] = node[keyOld];
		structure.entryProblems ~= GameStructIssue(keyOld~" key deprecated in favour of "~key, "rename");
		node.removeAt(keyOld);
	}
}
/++
+ Constructs a GameStruct from a parsed game.yml entry.
+/
GameStruct constructBlock(EntryType type)(ref Node node) {
	auto output = GameStruct();
	output.type = type;
	if ("Name" in node) {
		output.name = node["Name"].toString;
		output.entryProblems ~= GameStructIssue("Name key found", "Use name in block key instead");
		node.removeAt("Name");
	}
	deprecatedKey(node, output, "Labels");
	deprecatedKey(node, output, "Arguments");
	deprecatedKey(node, output, "Final State", "final processor state");
	deprecatedKey(node, output, "Description");
	deprecatedKey(node, output, "Size");
	deprecatedKey(node, output, "Format", "bpp");
	deprecatedKey(node, output, "Format", "BPP");
	deprecatedKey(node, output, "Base");
	deprecatedKey(node, output, "Locals", "localvars");
	if ("Pretty Name" in node) {
		output.prettyName = node["Pretty Name"].toString;
		node.removeAt("Pretty Name");
	}
	if ("Arguments" in node) {
		foreach (string arg, string val; node["Arguments"]) {
			output.arguments[arg] = val;
		}
		node.removeAt("Arguments");
	}
	if ("Initial State" in node) {
		foreach (string arg, string val; node["Initial State"]) {
			output.initialState[arg] = val;
		}
		node.removeAt("Initial State");
	}
	if ("Final State" in node) {
		foreach (string arg, string val; node["Final State"]) {
			output.finalState[arg] = val;
		}
		node.removeAt("Final State");
	}
	if ("Return Values" in node) {
		foreach (string arg, string val; node["Return Values"]) {
			output.returnValues[arg] = val;
		}
		node.removeAt("Return Values");
	}
	if ("Label States" in node) {
		foreach (string arg, Node val; node["Label States"]) {
			foreach (string label, string value; val) {
				output.labelStates[arg][label] = value;
			}
		}
		node.removeAt("Label States");
	}
	if ("Signed" in node) {
		if ((type == EntryType.pointer) || (type == EntryType.integer)) {
			output.isSigned = (cast(bool)node["Signed"]).ifThrown(node["Signed"].toString == "y");
		} else {
			output.entryProblems ~= GameStructIssue("Signed is meaningless in this context", "remove");
		}
		node.removeAt("Signed");
	}
	if ("References" in node) {
		output.references = node["References"].toString;
		node.removeAt("References");
	}
	if ("Base" in node) {
		if (type == EntryType.pointer) {
			output.pointerBase = cast(ulong)node["Base"];
		} else if (type == EntryType.integer) {
			output.numberBase = cast(ubyte)node["Base"];
		} else {
			output.entryProblems ~= GameStructIssue("Base is meaningless in this context", "remove");
		}
		node.removeAt("Base");
	}
	if ("Type" in node) {
		node.removeAt("Type");
	}
	if ("Offset" in node) {
		output.address = cast(ulong)node["Offset"];
		node.removeAt("Offset");
	}
	if ("Size" in node) {
		output.size = cast(typeof(output.size))node["Size"];
		node.removeAt("Size");
	}
	if ((type == EntryType.pointer) && (output.realSize > 8)) {
		output.entryProblems ~= GameStructIssue("Pointer size impossible", "change");
	}
	if ("Description" in node) {
		output.description = node["Description"].toString;
		node.removeAt("Description");
	}
	if ("Format" in node) {
		output.format = node["Format"].toString;
		node.removeAt("Format");
	}
	if ("Notes" in node) {
		output.notes = node["Notes"].toString;
		node.removeAt("Notes");
	}
	if ("Charset" in node) {
		output.charSet = node["Charset"].toString;
		node.removeAt("Charset");
	}
	if ("Endianness" in node) {
		output.endianness = node["Endianness"].toString == "Little" ? Endian.littleEndian : Endian.bigEndian;
		node.removeAt("Endianness");
	}
	if ("Terminator" in node) {
		if (node["Terminator"].isSequence()) {
			foreach (ubyte value; node["Terminator"]) {
				output.terminator ~= value;
			}
		} else {
			output.terminator = [cast(ubyte)node["Terminator"]];
		}
		node.removeAt("Terminator");
	}

	if ("Labels" in node) {
		foreach (ulong offset, string label; node["Labels"]) {
			if (offset > output.realSize) {
				output.entryProblems ~= GameStructIssue("Label offset greater than size of block", "Remove label");
			}
			if ((type != EntryType.array) && (type != EntryType.assembly)) {
				output.entryProblems ~= GameStructIssue("Labels found in unlabelable block", "Remove labels");
			}
			output.labels[offset] = label;
		}
		node.removeAt("Labels");
	}

	if ("Entries" in node) {
		if (type == EntryType.struct_) {
			try {
				foreach (string name, Node subnode; node["Entries"]) {
					GameStruct gamestruct = (cast(GameStruct)subnode).ifThrown(constructOldBlock(subnode));
					gamestruct.name = name;
					output.subEntries ~= gamestruct;
				}
			} catch (YAMLException) {
				foreach (Node subnode; node["Entries"]) {
					GameStruct gamestruct = (cast(GameStruct)subnode).ifThrown(constructOldBlock(subnode));
					output.subEntries ~= gamestruct;
				}
			}
			foreach (ref gameStruct; output.subEntries) {
				if (!gameStruct.address.isNull()) {
					gameStruct.entryProblems ~= GameStructIssue("Subentry contains offset", "remove");
				}
				if (gameStruct.subEntries.canFind!"a.name == b"(gameStruct.name)) {
					gameStruct.entryProblems ~= GameStructIssue("Duplicate entry found", "Rename entry");
				}
				if (gameStruct.name.toUpper() != gameStruct.name) {
					gameStruct.entryProblems ~= GameStructIssue("Name isn't uppercase", "rename, use Pretty Name instead");
				}
			}
		} else {
			output.entryProblems ~= GameStructIssue("Entries key found in type that isn't struct", "remove");
		}
		node.removeAt("Entries");
	}

	if ("Item Type" in node) {
		if (type == EntryType.array) {
			output.itemType = (cast(GameStruct)node["Item Type"]).ifThrown(constructOldBlock(node["Item Type"]));
			if (!output.itemType.address.isNull()) {
				output.entryProblems ~= GameStructIssue("Array prototype contains offset", "remove");
			}
		} else {
			output.entryProblems ~= GameStructIssue("Item type key found in type that isn't array", "remove");
		}
		node.removeAt("Item Type");
	}
	if ("Bit Values" in node) {
		if ((type != EntryType.integer) && (type != EntryType.bitField)) {
			output.entryProblems ~= GameStructIssue("Bit Values in non-integer type", "remove");
		}
		foreach (string bv; node["Bit Values"]) {
			output.bitValues ~= bv;
		}
		node.removeAt("Bit Values");
	}
	if ("Locals" in node) {
		if (type == EntryType.assembly) {
			foreach (ulong offset, string label; node["Locals"]) {
				output.localVariables[offset] = label;
			}
		} else {
			output.entryProblems ~= GameStructIssue("Local variables key found in type that isn't assembly", "remove");
		}
		node.removeAt("Locals");
	}
	if ("Values" in node) {
		if (type == EntryType.integer) {
			if (node["Values"].isMapping()) {
				foreach (ulong val, string label; node["Values"]) {
					output.values[val] = label;
				}
			} else if (node["Values"].isSequence()) {
				uint i = 0;
				foreach (string label; node["Values"]) {
					output.values[i++] = label;
				}
			} else {
				output.entryProblems ~= GameStructIssue("Invalid format for values key", "change to sequence of strings or map of integers:strings");
			}
		} else {
			output.entryProblems ~= GameStructIssue("Values key found in type that isn't integer", "remove");
		}
		node.removeAt("Values");
	}
	foreach (string k, Node v; node) {
		output.entryProblems ~= GameStructIssue("Unknown key: "~k, "remove");
	}
	return output;
}
/++
+ Loads a game.yml file.
+ Params:
+ path = Absolute or relative path to game.yml file.
+/
GameData loadGameFile(string path) {
	return loadCommon(Loader(cast(string)path.read()));
}
/++
+ Loads game.yml data from a pre-existing string.
+ Params:
+ data = Game.yml data.
+/
GameData loadGameFromString(string data) {
	return loadCommon(Loader(data.dup));
}
/++
+ Common code for loading game.yml data.
+/
private GameData loadCommon(Loader loader) {
	ScriptTable[ubyte] buildScriptTables(Node input) {
		ScriptTable[ubyte] output;
		ScriptTable recurseSubEntriesLength(Node val) {
			auto output = ScriptTable();
			if (val.isScalar()) {
				output.length = val.toString;
			} else {
				foreach (Node key, Node value; val) {
					if ((key == "default") || (key == "=")) {
						output.length = value.toString;
					} else {
						output.subtables[cast(ubyte)key] = recurseSubEntriesLength(value);
					}
				}
			}
			return output;
		}
		void recurseSubEntriesReplacements(Node val, ref ScriptTable[ubyte] output) {
			foreach (Node key, Node value; val) {
				if (value.isScalar()) {
					if (cast(ubyte)key !in output) {
						output[cast(ubyte)key] = ScriptTable();
					}
					output[cast(ubyte)key].stringReplacement = value.toString;
				}
			}
		}
		if ("Lengths" in input) {
			foreach (Node key, Node value; input["Lengths"]) {
				if (key == "=") {
					continue;
				}
				output[cast(ubyte)key] = recurseSubEntriesLength(value);
			}
		}
		if ("Replacements" in input) {
			recurseSubEntriesReplacements(input["Replacements"], output);
		}
		return output;
	}
	auto constructor = new Constructor;
	constructor.addConstructorMapping!constructAssemblyBlock(Tag("!assembly"));
	constructor.addConstructorMapping!constructDataBlock(Tag("!data"));
	constructor.addConstructorMapping!constructEmptyBlock(Tag("!empty"));
	constructor.addConstructorMapping!constructStructBlock(Tag("!struct"));
	constructor.addConstructorMapping!constructScriptBlock(Tag("!script"));
	constructor.addConstructorMapping!constructIntBlock(Tag("!int"));
	constructor.addConstructorMapping!constructArrayBlock(Tag("!array"));
	constructor.addConstructorMapping!constructPointerBlock(Tag("!pointer"));
	constructor.addConstructorMapping!constructBitfieldBlock(Tag("!bitfield"));
	constructor.addConstructorMapping!constructUnknownBlock(Tag("!unknown"));
	constructor.addConstructorMapping!constructUnknownBlock(Tag("!undefined"));
	constructor.addConstructorMapping!constructTileBlock(Tag("!tile"));
	constructor.addConstructorMapping!constructColorBlock(Tag("!color"));
	loader.constructor = constructor;
	auto document = loader.loadAll();
	GameData output;
	enforce(document.length >= 1, "No YAML documents found");
	enforce(document[0].isValid, "Invalid YAML found in document 0");
	enforce(document.length >= 2, "Missing game metadata or offset documentation");
	enforce(document[1].isValid, "Invalid YAML found in document 1");
	enforce(document[0].isMapping, "Invalid format for game metadata");
	enforce("Title" in document[0], "Missing title!");
	output.title = document[0]["Title"].toString;
	enforce("Country" in document[0], "Missing Country!");
	output.country = document[0]["Country"].toString;
	if ("Clean Hash" in document[0]) {
		output.hash = document[0]["Clean Hash"].toString;
		enforce(output.hash.length == 40, "Specified hash is not SHA1");
	}
	if ("Default Script" in document[0]) {
		output.defaultScript = document[0]["Default Script"].toString;
	}
	if (document[1].isMapping) {
		ulong lastOffset = 0;
		ulong lastSize = 0;
		string lastName;
		foreach (string name, Node node; document[1]) {
			try {
				GameStruct gamestruct = (cast(GameStruct)node).ifThrown(constructOldBlock(node));
				gamestruct.name = name;
				if (!gamestruct.address.isNull) {
					if (gamestruct.address < lastOffset) {
						gamestruct.entryProblems ~= GameStructIssue(lastName~" has greater offset", "move entry");
					}
					if (gamestruct.address < lastOffset+lastSize) {
						gamestruct.entryProblems ~= GameStructIssue("Overlap with "~lastName, "fix previous entry size");
					}
					lastOffset = gamestruct.address;
				}
				try {
					lastSize = gamestruct.realSize;
				} catch (Exception) {
					gamestruct.entryProblems ~= GameStructIssue("Invalid size", "Fix size");
				}
				lastName = name;
				if (name.toUpper() != name) {
					gamestruct.entryProblems ~= GameStructIssue("Name isn't uppercase", "rename, use Pretty Name instead");
				}
				if (gamestruct.size == "") {
					gamestruct.entryProblems ~= GameStructIssue("Missing size in root entry", "add size");
				}
				if (name in output.addresses) {
					gamestruct.entryProblems ~= GameStructIssue("Duplicate entry with this name exists", "rename or remove");
				}
				output.addresses[name] = gamestruct;
			} catch (Exception e) {
				e.msg = "Error in " ~ name ~ ": " ~ e.msg;
				throw e;
			}
		}
	}
	if ("Script Tables" in document[0]) {
		foreach (string tablename, Node table; document[0]["Script Tables"]) {
			output.scriptTables[tablename] = ScriptTable();
			output.scriptTables[tablename].subtables = buildScriptTables(table);
		}
	}
	return output;
}
enum isProperSource(T) = isInputRange!T && is(Unqual!(ElementType!T) == ubyte);
/++
+ Reads a chunk of game.yml-defined data from a ubyte input range.
+ Params:
+ source = Source of ubytes to read.
+ gameStruct = Definition of data to read.
+ gameData = Miscellaneous information required to read data correctly.
+/
YAMLType!T readYAMLType(T)(ref T source, GameStruct gameStruct, GameData gameData) if (isProperSource!T) {
	auto output = YAMLType!T();
	output.load(source, gameStruct, gameData);
	return output;
}
struct YAMLType(T) if (isProperSource!T) {
	private T* source;
	GameStruct info;
	GameData data;
	public ulong bytesRead;
	Algebraic!(BigInt, YAMLType[], YAMLType[string], ubyte[], string, uint[][], uint) value;
	EntryType type;
	alias value this;
	@disable size_t toHash();
	YAMLType opIndex(size_t index) {
		assert(value.peek!(YAMLType[]) !is null);
		return value.get!(YAMLType[])[index];
	}
	YAMLType opIndex(string index) {
		assert(value.peek!(YAMLType[string]) !is null);
		return value.get!(YAMLType[string])[index];
	}
	void load(ref T inSource, GameStruct inInfo, GameData inData) {
		source = &inSource;
		info = inInfo;
		data = inData;
		readValue();
	}
	protected void readValue() {
		if (!info.address.isNull) {
			(*source).popFrontN(cast(size_t) info.address.get);
		}
		type = info.type;
		final switch(info.type) {
			case EntryType.struct_:
				YAMLType[string] tmp;
				foreach (subEntry; info.subEntries) {
					auto entry = readYAMLType(*source, subEntry, data);
					tmp[subEntry.name] = entry;
					bytesRead += entry.bytesRead;
				}
				value = tmp;
				break;
			case EntryType.integer, EntryType.pointer, EntryType.bitField:
				BigInt tmp;
				foreach (position; 0..info.realSize) {
					tmp += ((*source).read!ubyte)<<(8*position);
					bytesRead++;
				}
				value = tmp;
				break;
			case EntryType.script:
				value = (*source).take(cast(size_t) info.realSize).array;
				bytesRead += info.realSize;
				break;
			case EntryType.array:
				YAMLType[] tmp;
				auto numBytesLeft = info.realSize;
				while (numBytesLeft > 0) {
					tmp ~= readYAMLType(*source, info.itemType, data);
					numBytesLeft -= tmp[$-1].bytesRead;
					bytesRead += tmp[$-1].bytesRead;
				}
				value = tmp;
				break;
			case EntryType.undefined, EntryType.null_, EntryType.assembly:
				value = (*source).take(cast(size_t) info.realSize).array;
				bytesRead += info.realSize;
				break;
			case EntryType.tile:
				value = (*source).take(cast(size_t) info.realSize).array;
				break;
			case EntryType.color:
				value = (*source).take(cast(size_t) info.realSize).array;
				break;
		}
	}
	Node toYAML() {
		auto output = Node(YAMLNull());
		final switch(info.type) {
			case EntryType.struct_:
				output = Node(value.get!(YAMLType[string]).keys, value.get!(YAMLType[string]).values.map!((x) => x.toYAML()).array);
				break;
			case EntryType.integer:
				auto value = value.get!BigInt.toLong();
				if (value in info.values) {
					output = Node(info.values[value]);
				} else if (info.bitValues.length > 0) {
					Node[] nodes;
					foreach (i, valueName; info.bitValues) {
						if (value & (1<<i)) {
							nodes ~= Node(valueName);
						}
					}
					output = Node(nodes);
				} else {
					output = Node(value);
				}
				break;
			case EntryType.pointer, EntryType.bitField:
				output = Node(value.get!BigInt.toLong()); break;
			case EntryType.script:
				output = Node(this.toString()); break;
			case EntryType.array:
				output = Node(value.get!(YAMLType[]).map!((x) => x.toYAML()).array);
				break;
			case EntryType.undefined, EntryType.null_:
				output = Node(value.get!(ubyte[]).map!((x) => Node(x)).array);
				break;
			case EntryType.tile:
				output = Node(value.get!(uint[][]).map!((x) => Node(x.map!((x) => Node(x)).array)).array);
				break;
			case EntryType.color:
				output = Node(value.get!uint);
				break;
			case EntryType.assembly:
				output = Node(value.get!(ubyte[]).map!((x) => Node(x)).array);
				break;
		}
		return output;
	}
	ubyte[] toBytes() {
		ubyte[] output;
		final switch(info.type) {
			case EntryType.struct_:
				writefln("s: %s", value);
				foreach (subEntry; info.subEntries) {
					output ~= value[subEntry.name].get!YAMLType.toBytes();
				}
				break;
			case EntryType.integer, EntryType.pointer, EntryType.bitField:
				output = new ubyte[](cast(size_t) info.realSize);
				foreach (i, ref byteVal; output) {
					byteVal = cast(ubyte) ((value.get!BigInt.toLong()>>(i*8))&0xFF);
				}
				break;
			case EntryType.script:
				output = value.get!(ubyte[]);
				break;
			case EntryType.array:
				foreach (subval; value.get!(YAMLType[])) {
					output ~= subval.toBytes();
				}
				break;
			case EntryType.undefined, EntryType.null_:
				output = value.get!(ubyte[]);
				break;
			case EntryType.tile:
				output = value.get!(ubyte[]);
				break;
			case EntryType.color:
				output = value.get!(ubyte[]);
				break;
			case EntryType.assembly:
				output = value.get!(ubyte[]);
				break;
		}
		return output;
	}
	public bool opEquals(const int val) const {
		enforce(info.type == EntryType.integer);
		return value == BigInt(val);
	}
	public bool opEquals(const string val) const {
		enforce(info.type == EntryType.script);
		return value.get!(ubyte[]) == val.representation;
	}
	public bool opEquals(T)(const T[] val) const {
		enforce(info.type == EntryType.array);
		return zip(val, value.get!(YAMLType[]))
			.filter!(x => x[0] != x[1])
			.empty;
	}
	public bool opEquals(K,string)(const K[string] val) const {
		enforce(info.type == EntryType.struct_);
		if (val.keys == value.get!(YAMLType[string]).keys) {
			foreach (key; val.keys) {
				if (value.get!(YAMLType[string])[key] != val[key]) {
					return false;
				}
			}
			return true;
		}
		return false;
	}
	public string toString() const {
		final switch (info.type) {
			case EntryType.script:
				string charset;
				if (info.charSet != "") {
					charset = info.charSet;
				} else {
					charset = data.defaultScript;
				}
				if (charset in data.scriptTables) {
					return data.scriptTables[charset].replaceStr(value.get!(ubyte[]));
				} else if (charset == "ASCII") {
					string output;
					auto codec = EncodingScheme.create("ASCII");
					const(ubyte)[] copy_buffer = value.get!(ubyte[]);
					while (copy_buffer.length > 0) {
						output ~= cast(char) codec.safeDecode(copy_buffer);
					}
					return output;
				} else if (charset == "UTF-8") {
					string output;
					auto codec = EncodingScheme.create("utf-8");
					const(ubyte)[] copy_buffer = value.get!(ubyte[]);
					while (copy_buffer.length > 0) {
						output ~= cast(char) codec.safeDecode(copy_buffer);
					}
					return output;
				} else {
					assert(0, "Unsupported character encoding");
				}
			case EntryType.struct_, EntryType.pointer, EntryType.bitField, EntryType.array, EntryType.tile, EntryType.undefined, EntryType.null_, EntryType.color, EntryType.assembly:
				assert(0);
			case EntryType.integer:
				return value.get!BigInt.text;
		}
	}
}
unittest {
	auto gd = GameData();
	{
		ubyte[] testdata = [0, 1, 2, 3];
		auto info_int = GameStruct();
		info_int.size = "4";
		info_int.type = EntryType.integer;
		info_int.address = 0;
		auto t = readYAMLType(testdata, info_int, gd);
		assert(t == 0x03020100);
		assert(t.toBytes() == [0, 1, 2, 3]);
	}
	{
		ubyte[] testdata = [0, 1, 2, 3];
		auto info_int = GameStruct();
		info_int.size = "3";
		info_int.type = EntryType.integer;
		info_int.address = 0;
		auto t = readYAMLType(testdata, info_int, gd);
		assert(t == 0x020100);
		assert(t.toBytes() == [0, 1, 2]);
	}
	{
		ubyte[] testdata = ['T', 'e', 's', 't'];
		auto infoStr = GameStruct();
		infoStr.size = "4";
		infoStr.type = EntryType.script;
		infoStr.address = 0;
		infoStr.charSet = "ASCII";
		auto t = readYAMLType(testdata, infoStr, gd);
		assert(t == "Test");
		assertThrown(t == 4);
		assert(t.toBytes() == "Test");
		assert(t == "Test");
	}
	{
		ubyte[] testdata = ['T', 'e', 's', 't'];
		auto infoStr = GameStruct();
		infoStr.size = "4";
		infoStr.type = EntryType.script;
		infoStr.address = 0;
		infoStr.charSet = "UTF-8";
		auto t = readYAMLType(testdata, infoStr, gd);
		assert(t == "Test");
		assert(t.toBytes() == "Test");
		assert(t == "Test");
	}
	{
		ubyte[] testdata = [0, 1, 2, 3];
		auto infoArray = GameStruct();
		infoArray.size = "4";
		infoArray.type = EntryType.array;
		infoArray.address = 0;
		infoArray.itemType = GameStruct();
		infoArray.itemType.size = "2";
		infoArray.itemType.type = EntryType.integer;
		auto t = readYAMLType(testdata, infoArray, gd);
		assert(t == [0x0100, 0x0302]);
		assertThrown(t == "Test");
		assertThrown(t == 0x03020100);
		assert(t.toBytes() == [0, 1, 2, 3]);
	}
	{
		ubyte[] testdata = [0, 1, 2, 3];
		auto info_struct = GameStruct();
		info_struct.size = "4";
		info_struct.type = EntryType.struct_;
		GameStruct miniInt = GameStruct();
		miniInt.size = "2";
		miniInt.type = EntryType.integer;
		miniInt.name = "A";
		auto miniInt2 = GameStruct();
		miniInt2.name = "B";
		miniInt2.size = "2";
		miniInt2.type = EntryType.integer;
		info_struct.subEntries = [miniInt, miniInt2];
		info_struct.address = 0;
		auto t = readYAMLType(testdata, info_struct, gd);
		assert(t["A"] == 0x0100);
		assert(t["B"] == 0x0302);
		assert(t == ["A": 0x0100, "B": 0x0302]);
	}
}
/++
+ Translates an EntryType to its associated YAML tag.
+/
string tag(EntryType type) {
	final switch (type) {
		case EntryType.integer: return "!int";
		case EntryType.null_: return "!empty";
		case EntryType.struct_: return "!struct";
		case EntryType.script: return "!script";
		case EntryType.assembly: return "!assembly";
		case EntryType.array: return "!array";
		case EntryType.undefined: return "!undefined";
		case EntryType.pointer: return "!pointer";
		case EntryType.bitField: return "!bitfield";
		case EntryType.tile: return "!tile";
		case EntryType.color: return "!color";
	}
}
/++
+ Converts an array of GameStructs to a name:YAML node mapping..
+ Bugs: Somewhat incomplete.
+/
Node[string] toYAML(GameStruct[] data...) {
	Node[string] output;
	foreach (datum; data) {
		Node[string] ydata;
		if ((datum.type == EntryType.integer) && datum.bitValues.length > 0) {
			ydata["Bit Values"] = Node(datum.bitValues);
		}
		if (datum.type == EntryType.array) {
			ydata["Item Type"] = datum.itemType.toYAML().values[0];
		}
		if (datum.type == EntryType.struct_) {
			Node[string] nodes;
			foreach (subentry; datum.subEntries) {
				nodes[subentry.name] = subentry.toYAML().values[0];
			}
			ydata["Entries"] = Node(nodes);
		}
		ydata["Size"] = Node(datum.size);
		output[datum.name] = Node(ydata, datum.type.tag);
	}
	return output;
}
/++
+ Determines the name of the entry the specified offset matches.
+ Params:
+ data = Game definitions to search in.
+ addr = Address to look for.
+/
Nullable!(string,"") getNameFromAddr(GameData data, ulong addr) pure @safe {
	foreach (entry; data.addresses) {
		if (entry.address == addr) {
			return Nullable!(string, "")(entry.name);
		}
	}
	return Nullable!(string, "")(null);
}
unittest {
	auto data = loadGameFromString(`---
Platform: test
Title: Test
Country: None
...
---
One: !assembly
  Labels:
    1: Test
    2: Test2
  Offset: 0
  Size: 3`);
	assert(getNameFromAddr(data, 0) == "One");
	assert(getNameFromAddr(data, 1).isNull);
}
/++
+ Generates an appropriate name for a given address using the supplied
+ GameData.
+ Params:
+ data = Game definitions to search in.
+ addr = Address to generate name for.
+/
string offsetLabel(GameData data, ulong addr) {
	auto foundEntry = data.addresses.values.find!((x, y) => (x.address <= addr) && (x.address+x.realSize > addr))(addr);
	if (foundEntry.empty) {
		return format("%X", addr);
	} else if (foundEntry.front.type == EntryType.array) {
		if ((addr - foundEntry.front.address) in foundEntry.front.labels) {
			return format("%s[%s]", foundEntry.front.name, foundEntry.front.labels[addr - foundEntry.front.address]);
		}
		return format("%s[%d]", foundEntry.front.name, (addr - foundEntry.front.address) / foundEntry.front.itemType.realSize);
	} else if (foundEntry.front.address == addr) {
		return foundEntry.front.name;
	} else if ((addr - foundEntry.front.address) in foundEntry.front.labels) {
		return format("%s#%s", foundEntry.front.name, foundEntry.front.labels[addr - foundEntry.front.address]);
	}
	return format("%s+%s", foundEntry.front.name, addr - foundEntry.front.address);
}
unittest {
	auto data = loadGameFromString(`---
Platform: test
Title: Test
Country: None
...
---
One: !array
  Labels:
    1: Test
    2: Test2
  Offset: 0
  Item Type: !int
    Size: 1
  Size: 4
Two: !assembly
  Offset: 4
  Size: 2`);
	assert(offsetLabel(data, 0) == "One[0]");
	assert(offsetLabel(data, 1) == "One[Test]");
	assert(offsetLabel(data, 2) == "One[Test2]");
	assert(offsetLabel(data, 3) == "One[3]");
	assert(offsetLabel(data, 4) == "Two");
}
/++
+ Converts a YAML node to its string representation.
+/
string yamlString(Node data) {
	auto buf = new OutBuffer();
	auto dumper = Dumper();
	dumper.dump(buf, data);
	return buf.text;
}

/++
+ Exception thrown on invalid size definitions.
+/
class BadSizeException : GameDataException {
	private this(string file = __FILE__, int line = __LINE__) {
		super("Unable to parse undefined size", file, line);
	}
	private this(in string size, string file = __FILE__, int line = __LINE__) {
		super("Unable to parse size: "~size, file, line);
	}
}
/++
+ Exception thrown when an address is not found in the data.
+/
class AddressNotFoundException : GameDataException {
	private this(in string addr, string file = __FILE__, int line = __LINE__) {
		super("Address not found: "~addr, file, line);
	}
}
/++
+ Exception thrown on severe issues with game.yml files.
+/
class GameDataException : Exception {
	private this(in string msg, string file = __FILE__, int line = __LINE__) {
		super(msg, file, line);
	}
}