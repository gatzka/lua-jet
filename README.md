# About

lua-jet is a [Jet](http://lipp.github.io/jet) daemon and peer implementation written in Lua. 
[![Build Status](https://travis-ci.org/lipp/jet.png?branch=master)](https://travis-ci.org/lipp/jet/builds)

# Installation

    $ git clone https://github.com/lipp/jet.git
    $ cd jet
    $ sudo luarocks make rockspecs/jet-scm-1.rockspec

# Doc

For general information, visit the [Jet Homepage](http://lipp.github.io/jet). Look at the [API.md](https://github.com/lipp/lua-jet/blob/master/API.md), the [examples](https://github.com/lipp/lua-jet/tree/master/examples) or the [busted](https://github.com/lipp/busted/tree/add-finally) test [spec files](https://github.com/lipp/lua-jet/tree/master/spec).

# Tests

To run the tests, [busted with finally support](https://github.com/lipp/busted/tree/add-finally) needs to be installed:

    $ git clone https://github.com/lipp/busted.git
	$ cd busted
    $ git checkout add-finally
	$ ./try
	
If all is in place, run the tests from within the lua-jet dir like this:

    $ busted spec
