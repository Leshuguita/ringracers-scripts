# This is a fork!

currently allows for translating text (for now, just what's commonly seen by players), and has a spanish translation already.

if you don't need that, you should probably just use the [original addon](https://github.com/GenericHeroGuy/ringracers-scripts) instead.

---

# ringracers-scripts

Lots of Lua scripts for [Dr. Robotnik's Ring Racers](https://www.kartkrew.org/)

## Building

PK3s are built with pk3make.py, a custom-made zip file creator supporting partial updates and full control over load order.
pk3make uses Zopfli by default for maximum compression; if not installed, zlib is used instead.

For example, to build sglua:

`./pk3make.py build/sglua.txt`

Add `--lang <code>` to build the file in a specific language. By default uses english (`en`).
Add `-j8` to build with 8 cores, `-z` to force zlib, or `-o` to change the output file.
More options can be found with `--help`.

## License?

It's all open assets. Go nuts!
