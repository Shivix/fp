# fp

fp is heavily based on [fzy](https://github.com/jhawthorn/fzy).

<img alt="fp showcase" src="https://github.com/Shivix/fp/blob/master/examples/fp.gif" width="1200" />

## Why use this over fzy, fzf, pick, skim, etc?
It's much simpler and lighter weight that most fuzzy finders. If you need the features that these
others provide then stop right here, however you'd be surprised how little you truly need.

Most other fuzzy matchers sort based on the length of a match. fp favours matches on consecutive
letters and starts of words. This allows matching using acronyms or different parts of the path.

fp is designed to be used both as an editor plugin and on the command line.
Rather than clearing the screen, fp displays its interface directly below the current cursor
position, scrolling the screen if necessary.

As for why use it over Fzy? If you're already using it and are happy with it then stick to it, but
I intend to keep fp well maintained and there are a couple differences which you may prefer such as:
* support for multiple selections, akin to fzf's --multi but works by default.
* single threaded (less hardware usage and still faster in most cases)

## Installation
```bash
$ make install
# Only has fish completion right now.
$ make install-completion
```

## Usage
fp is purely a picker, it must be fed data to pick from.
```bash
# Search through local files
fd | fp
# Narrow down a grep line
rg test | fp
# Can be used non-interactively to add fuzzy finding where you wouldn't other wise.
fp -e "fuzzypattern" <file.txt | head -1
```

## Sorting
fp attempts to present the best matches first. The following considerations are weighted when sorting:\
It prefers consecutive characters: `file` will match <tt><b>file</b></tt> over <tt><b>fil</b>t<b>e</b>r</tt>.\
It prefers matching the beginning of words: `amp` is likely to match <tt><b>a</b>pp/<b>m</b>odels/<b>p</b>osts.rb</tt>.\
It prefers shorter matches: `abce` matches <tt><b>abc</b>d<b>e</b>f</tt> over <tt><b>abc</b> d<b>e</b></tt>.\
It prefers shorter candidates: `test` matches <tt><b>test</b>s</tt> over <tt><b>test</b>ing</b></tt>.
