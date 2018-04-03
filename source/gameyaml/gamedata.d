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

import dyaml;
import libdmathexpr.mathexpr;

auto dumpStr(Node data) {
	import dyaml.stream;
	auto stream = new YMemoryStream();
	auto node = Node([1, 2, 3, 4, 5]);
	Dumper(stream).dump(node);
	return cast(string)stream.data;
}

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
	///Platform
	string platform;
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
	///Version of the game
	string version_;
	///Address definitions for the game
	GameStruct[string][ulong] addresses;
	string toString() {
		string[] output;
		output ~= format("Game: %s (%s)", title, country);
		output ~= format("CPU: %s", processor.architecture);
		if (defaultScript != defaultScript.init) {
			output ~= format("Default Script Format: %s", defaultScript);
		}
		foreach (id, addrs; addresses)
			output ~= format("[%s] - %(%s, %)", id, addrs.keys);
		return output.join("\n\t");
	}
}
/++
+ Script table information. Represents a variable-length byte
+ sequence<->string mapping.
+/
struct ScriptTable {
	struct ScriptByte {
		Nullable!ubyte val;
		bool isWildcard;
		bool opEquals(const ubyte datum) const @safe pure nothrow @nogc {
			if (isWildcard) {
				return true;
			}
			assert(!val.isNull);
			return val == datum;
		}
	}
	struct Entry {
		///String to replace a byte sequence with
		Nullable!string stringReplacement;
		///Number of bytes making up this sequence. May be a math expression.
		ScriptByte[] sequence;

		bool match(const ubyte[] bytes) const {
			if (sequence.length < bytes.length) {
				return false;
			}
			foreach (reference, datum; lockstep(sequence, bytes)) {
				if (reference != datum) {
					return false;
				}
			}
			return true;
		}
	}
	Entry[] entries;
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
		ubyte[] remaining = bytes.dup;
		bool matched;
		while (!remaining.empty) {
			matched = false;
			foreach (entry; entries.filter!(x => x.sequence.length <= remaining.length)) {
				if (entry.match(remaining[0..entry.sequence.length])) {
					if (entry.stringReplacement.isNull) {
						output ~= format!"%([%s]%)"(remaining[0..entry.sequence.length]);
					} else {
						output ~= entry.stringReplacement;
					}
					remaining = remaining[entry.sequence.length..$];
					matched = true;
				}
			}
			if (!matched) {
				output ~= format!"%([%s]%)"(remaining[0..1]);
				remaining = remaining[1..$];
			}
		}
		return output;
	}
}
unittest {
	auto data = loadGameFromStrings(import("test1.metadata.yml"), import("test1.yml"));
	assert(data.scriptTables["Test"].replaceStr([0]) == "Yes");
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
			return cast(int)(size - b.size);
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
	///Size of data. May not be set if terminator or calculated size is used.
	Nullable!ulong size;
	///Size of data, represented by a math expression. Not required unless Size and Terminator are absent.
	Nullable!string calculatedSize;
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
	///Memory space this entry exists in. Typically only one such space exists.
	size_t memorySpaceID;
	/++
	+ The real size of this data structure, if it can be calculated.
	+ Params:
	+   vars = Other integers parsed before reading this entry. Used in math expression-ized size entries.
	+ Throws: BadSizeException if a size cannot be calculated.
	+ Returns: Size of the data structure.
	+/
	ulong realSize(real[string] vars = null) {
		if (size.isNull) {
			return parseMathExpr(calculatedSize).evaluate(vars).to!ulong();
		}
		return size;
	}
	///Short string representation of this entry.
	string toString() const {
		return std.format.format("%s: %s,%s", name, address, size);
	}
}
/++
+ Constructs a GameStruct from a parsed game.yml entry.
+/
GameStruct asGameStruct(ref Node node, bool isRoot = false) {
	auto output = GameStruct();
	switch(node["Type"].as!string) {
		case "array":
			output.type = EntryType.array;
			break;
		case "assembly":
			output.type = EntryType.assembly;
			break;
		case "int":
			output.type = EntryType.integer;
			break;
		case "struct":
			output.type = EntryType.struct_;
			break;
		case "pointer":
			output.type = EntryType.pointer;
			break;
		case "null":
			output.type = EntryType.null_;
			break;
		case "bitfield":
			output.type = EntryType.bitField;
			break;
		case "tile":
			output.type = EntryType.tile;
			break;
		case "script":
			output.type = EntryType.script;
			break;
		case "unknown":
			output.type = EntryType.undefined;
			break;
		case "empty":
			output.type = EntryType.undefined;
			break;
		default: throw new Exception("Invalid type: "~node["Type"].as!string);
	}
	if ("Name" in node) {
		output.name = node["Name"].as!string;
	}
	if ("Pretty Name" in node) {
		output.prettyName = node["Pretty Name"].as!string;
	}
	if ("Arguments" in node) {
		foreach (string arg, string val; node["Arguments"]) {
			output.arguments[arg] = val;
		}
	}
	if ("Initial State" in node) {
		foreach (string arg, string val; node["Initial State"]) {
			output.initialState[arg] = val;
		}
	}
	if ("Final State" in node) {
		foreach (string arg, string val; node["Final State"]) {
			output.finalState[arg] = val;
		}
	}
	if ("Return Values" in node) {
		foreach (string arg, string val; node["Return Values"]) {
			output.returnValues[arg] = val;
		}
	}
	if ("Label States" in node) {
		string offset;
		string[string] states;
		foreach (Node val; node["Label States"]) {
			foreach (string label, string value; val) {
				if (label == "Offset") {
					offset = value;
				} else {
					states[label] = value;
				}
			}
		}
		output.labelStates[offset] = states;
	}
	if ("Signed" in node) {
		if ((output.type == EntryType.pointer) || (output.type == EntryType.integer)) {
			output.isSigned = (node["Signed"].as!bool).ifThrown(node["Signed"].as!string == "y");
		}
	}
	if ("References" in node) {
		output.references = node["References"].as!string;
	}
	if ("Base" in node) {
		if (output.type == EntryType.pointer) {
			output.pointerBase = node["Base"].as!ulong;
		} else if (output.type == EntryType.integer) {
			output.numberBase = node["Base"].as!ubyte;
		}
	}
	enforce(!isRoot || ("Offset" in node), "Required offset key missing");
	if ("Offset" in node) {
		output.address = node["Offset"].as!ulong;
	}
	if ("Size" in node) {
		output.size = node["Size"].as!ulong;
	}
	if ("Description" in node) {
		output.description = node["Description"].as!string;
	}
	if ("Format" in node) {
		output.format = node["Format"].as!string;
	}
	if ("Notes" in node) {
		output.notes = node["Notes"].as!string;
	}
	if ("Charset" in node) {
		output.charSet = node["Charset"].as!string;
	}
	if ("Endianness" in node) {
		output.endianness = node["Endianness"].as!string == "Little" ? Endian.littleEndian : Endian.bigEndian;
	}
	if ("Terminator" in node) {
		if (node["Terminator"].isSequence()) {
			foreach (ubyte value; node["Terminator"]) {
				output.terminator ~= value;
			}
		} else {
			output.terminator = [node["Terminator"].as!ubyte];
		}
	}

	if ("Labels" in node) {
		enforce(node["Labels"].isSequence, "Labels must be a sequence");
		foreach (Node label; node["Labels"]) {
			output.labels[label["Offset"].as!ulong] = label["Name"].as!string;
		}
	}

	if ("Entries" in node) {
		if (output.type == EntryType.struct_) {
			try {
				foreach (string name, Node subnode; node["Entries"]) {
					GameStruct gamestruct = subnode.asGameStruct;
					gamestruct.name = name;
					output.subEntries ~= gamestruct;
				}
			} catch (YAMLException) {
				foreach (Node subnode; node["Entries"]) {
					GameStruct gamestruct = subnode.asGameStruct;
					output.subEntries ~= gamestruct;
				}
			}
		}
	}

	if ("Item Type" in node) {
		if (output.type == EntryType.array) {
			output.itemType = node["Item Type"].asGameStruct;
		}
	}
	if ("Bit Values" in node) {
		foreach (string bv; node["Bit Values"]) {
			output.bitValues ~= bv;
		}
	}
	if ("Locals" in node) {
		if (output.type == EntryType.assembly) {
			foreach (Node local; node["Locals"]) {
				output.localVariables[local["Offset"].as!ulong] = local["Name"].as!string;
			}
		}
	}
	if ("Values" in node) {
		if (output.type == EntryType.integer) {
			if (node["Values"].isMapping()) {
				foreach (ulong val, string label; node["Values"]) {
					output.values[val] = label;
				}
			} else if (node["Values"].isSequence()) {
				uint i = 0;
				foreach (string label; node["Values"]) {
					output.values[i++] = label;
				}
			}
		}
	}
	return output;
}
/++
+ Loads a game.yml file.
+ Params:
+ path = Absolute or relative path to game definition folder.
+/
GameData loadGameFiles(string path) {
	import std.file : dirEntries, SpanMode;
	import std.path : baseName;
	Loader[] docs;
	foreach (foundDoc; dirEntries(path, "*.yml", SpanMode.shallow)) {
		if (baseName(foundDoc) != "metadata.yml") {
			docs ~= Loader(foundDoc);
		}
	}
	return loadCommon(Loader(path~"/metadata.yml"), docs);
}
///
@system unittest {
	import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
	auto testLocation = tempDir~"/filetest/";
	mkdir(testLocation);
	scope(exit) rmdirRecurse(testLocation);
	toFile(import("test1.yml"), testLocation~"/game.yml");
	toFile(import("test1.metadata.yml"), testLocation~"/metadata.yml");
	auto data = loadGameFiles(testLocation);
	assert("One" in data.addresses[0]);
	assert(data.title == "Test");
}
/++
+ Loads game.yml data from a pre-existing string.
+ Params:
+ data = Game.yml data.
+/
GameData loadGameFromStrings(string metadata, string[] definitions...) {
	Loader[] docs;
	foreach (definition; definitions) {
		docs ~= Loader.fromString(definition.dup);
	}
	return loadCommon(Loader.fromString(metadata.dup), docs);
}
/++
+ Common code for loading game.yml data.
+/
private GameData loadCommon(Loader metadataLoader, Loader[] definitionLoaders...) {
	GameData output;
	{
		auto document = metadataLoader.load();
		enforce(document.isValid, "Invalid YAML found in document 0");
		enforce(document.isMapping, "Invalid format for game metadata");
		enforce("Title" in document, "Missing title!");
		enforce("Country" in document, "Missing Country!");
		enforce("Version" in document, "Missing Version!");
		enforce("Version" in document, "Missing Platform!");
		enforce("SHA256" in document, "Missing Hash!");
		output.title = document["Title"].as!string;
		output.platform = document["Platform"].as!string;
		output.country = document["Country"].as!string;
		output.version_ = document["Version"].as!string;
		output.hash = document["SHA256"].as!string;
		if ("Default Script" in document) {
			output.defaultScript = document["Default Script"].as!string;
		}
		if ("Script Tables" in document) {
			foreach (string tableName, Node table; document["Script Tables"]) {
				output.scriptTables[tableName] = ScriptTable();
				foreach (Node tableEntry; table) {
					auto entry = ScriptTable.Entry();
					if ("Replacement" in tableEntry) {
						entry.stringReplacement = tableEntry["Replacement"].as!string;
					}
					foreach (Node seqByte; tableEntry["Sequence"]) {
						if (seqByte.as!string == "XX") {
							entry.sequence ~= ScriptTable.ScriptByte(Nullable!ubyte.init, true);
						} else {
							entry.sequence ~= ScriptTable.ScriptByte(Nullable!ubyte(seqByte.as!ubyte), false);
						}
					}
					output.scriptTables[tableName].entries ~= entry;
				}
			}
		}
	}
	foreach (memSpaceID, definitionDoc; definitionLoaders) {
		auto document = definitionDoc.load();
		if (document.isMapping) {
			ulong lastOffset = 0;
			ulong lastSize = 0;
			string lastName;
			foreach (string name, Node node; document) {
				try {
					GameStruct gamestruct = node.asGameStruct(true);
					gamestruct.name = name;
					if (!gamestruct.address.isNull) {
						lastOffset = gamestruct.address;
					}
					lastSize = gamestruct.realSize;
					lastName = name;
					output.addresses[memSpaceID][name] = gamestruct;
				} catch (Exception e) {
					e.msg = "Error in " ~ name ~ ": " ~ e.msg;
					throw e;
				}
			}
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
					enforce(!(*source).empty, "Error while reading "~info.name);
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
		}
	}
	import std.json;
	JSONValue toJSON() {
		JSONValue output;
		final switch(info.type) {
			case EntryType.struct_:
				foreach (key, val; value.get!(YAMLType[string])) {
					output[key] = val.toJSON();
				}
				break;
			case EntryType.integer:
				auto value = value.get!BigInt.toLong();
				if (value in info.values) {
					output = JSONValue(info.values[value]);
				} else if (info.bitValues.length > 0) {
					JSONValue[] nodes;
					foreach (i, valueName; info.bitValues) {
						if (value & (1<<i)) {
							nodes ~= JSONValue(valueName);
						}
					}
					output = JSONValue(nodes);
				} else {
					output = JSONValue(value);
				}
				break;
			case EntryType.pointer, EntryType.bitField:
				output = JSONValue(value.get!BigInt.toLong());
				break;
			case EntryType.script:
				output = JSONValue(this.toString());
				break;
			case EntryType.array:
				JSONValue[] arr;
				foreach (val; value.get!(YAMLType[])) {
					arr ~= val.toJSON();
				}
				output = JSONValue(arr);
				break;
			case EntryType.undefined, EntryType.null_:
				output = JSONValue(value.get!(ubyte[]));
				break;
			case EntryType.tile:
				output = JSONValue(value.get!(uint[]));
				break;
			case EntryType.assembly:
				output = JSONValue(value.get!(ubyte[]));
				break;
		}
		return output;
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
			case EntryType.struct_, EntryType.pointer, EntryType.bitField, EntryType.array, EntryType.tile, EntryType.undefined, EntryType.null_, EntryType.assembly:
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
		info_int.size = 4;
		info_int.type = EntryType.integer;
		info_int.address = 0;
		auto t = readYAMLType(testdata, info_int, gd);
		assert(t == 0x03020100);
		assert(t.toBytes() == [0, 1, 2, 3]);
		assert(t.toYAML().as!int == 0x03020100);
		assert(t.toJSON().integer == 0x03020100);
	}
	{
		ubyte[] testdata = [0, 1, 2, 3];
		auto info_int = GameStruct();
		info_int.size = 3;
		info_int.type = EntryType.integer;
		info_int.address = 0;
		auto t = readYAMLType(testdata, info_int, gd);
		assert(t == 0x020100);
		assert(t.toBytes() == [0, 1, 2]);
		assert(t.toYAML().as!int == 0x020100);
		assert(t.toJSON().integer == 0x020100);
	}
	{
		ubyte[] testdata = ['T', 'e', 's', 't'];
		auto infoStr = GameStruct();
		infoStr.size = 4;
		infoStr.type = EntryType.script;
		infoStr.address = 0;
		infoStr.charSet = "ASCII";
		auto t = readYAMLType(testdata, infoStr, gd);
		assert(t == "Test");
		assertThrown(t == 4);
		assert(t.toBytes() == "Test");
		assert(t == "Test");
		assert(t.toYAML().as!string == "Test");
		assert(t.toJSON().str == "Test");
	}
	{
		ubyte[] testdata = ['T', 'e', 's', 't'];
		auto infoStr = GameStruct();
		infoStr.size = 4;
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
		infoArray.size = 4;
		infoArray.type = EntryType.array;
		infoArray.address = 0;
		infoArray.itemType = GameStruct();
		infoArray.itemType.size = 2;
		infoArray.itemType.type = EntryType.integer;
		auto t = readYAMLType(testdata, infoArray, gd);
		assert(t == [0x0100, 0x0302]);
		assertThrown(t == "Test");
		assertThrown(t == 0x03020100);
		assert(t.toBytes() == [0, 1, 2, 3]);
		assert(t.toYAML()[0].as!int == 0x0100);
		assert(t.toYAML()[1].as!int == 0x0302);
		assert(t.toJSON()[0].integer == 0x0100);
		assert(t.toJSON()[1].integer == 0x0302);
	}
	{
		ubyte[] testdata = [0, 1, 2, 3];
		auto info_struct = GameStruct();
		info_struct.size = 4;
		info_struct.type = EntryType.struct_;
		GameStruct miniInt = GameStruct();
		miniInt.size = 2;
		miniInt.type = EntryType.integer;
		miniInt.name = "A";
		auto miniInt2 = GameStruct();
		miniInt2.name = "B";
		miniInt2.size = 2;
		miniInt2.type = EntryType.integer;
		info_struct.subEntries = [miniInt, miniInt2];
		info_struct.address = 0;
		auto t = readYAMLType(testdata, info_struct, gd);
		assert(t["A"] == 0x0100);
		assert(t["B"] == 0x0302);
		assert(t == ["A": 0x0100, "B": 0x0302]);
		assert(t.toYAML()["A"].as!int == 0x0100);
		assert(t.toYAML()["B"].as!int == 0x0302);
		assert(t.toJSON()["A"].integer == 0x0100);
		assert(t.toJSON()["B"].integer == 0x0302);
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
		ydata["Size"] = Node(datum.size.get);
		output[datum.name] = Node(ydata);
	}
	return output;
}
/++
+ Determines the name of the entry the specified offset matches.
+ Params:
+ data = Game definitions to search in.
+ addr = Address to look for.
+ memSpace = Memory space to look in (usually zero)
+/
Nullable!(string,"") getNameFromAddr(GameData data, ulong addr, ulong memSpace = 0) pure @safe {
	foreach (entry; data.addresses[memSpace]) {
		if (entry.address == addr) {
			return Nullable!(string, "")(entry.name);
		}
	}
	return Nullable!(string, "")(null);
}
unittest {
	auto data = loadGameFromStrings(import("test1.metadata.yml"), import("test1.yml"));
	assert(getNameFromAddr(data, 0) == "One");
	assert(getNameFromAddr(data, 1).isNull);
}
/++
+ Generates an appropriate name for a given address using the supplied
+ GameData.
+ Params:
+ data = Game definitions to search in.
+ addr = Address to generate name for.
+ memSpace = Memory space to search.
+/
string offsetLabel(GameData data, ulong addr, ulong memSpace = 0) {
	auto foundEntry = data.addresses[memSpace].values.find!((x, y) => (x.address <= addr) && (x.address+x.realSize > addr))(addr);
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
	auto data = loadGameFromStrings(import("test2.metadata.yml"), import("test2.yml"));
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
	return dumpStr(data);
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