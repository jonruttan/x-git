#!/bin/sh
# tests/card-run.sh FILE -- run one program of docs/card.md, for the bundle
# kit's card check.  X is the x under test.
#
# A program is shell, read in a new, empty directory, where `git` is
# `x -l git --`.  The user's and the system's configuration are not read,
# the first branch is main, and the identity and the clock are fixed, so a
# commit's name is the same wherever the program runs.
x=${X:-x}
case $x in */*) x=$(cd "$(dirname "$x")" && pwd)/$(basename "$x") ;; esac
file=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
d=$(mktemp -d) || exit 1
trap 'rm -rf "$d"' EXIT
mkdir "$d/work"
printf '[init]\n\tdefaultBranch = main\n' > "$d/gitconfig"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$d/gitconfig" TZ=UTC
export GIT_AUTHOR_NAME=Ada GIT_AUTHOR_EMAIL=ada@example.org
export GIT_COMMITTER_NAME=Ada GIT_COMMITTER_EMAIL=ada@example.org
export GIT_AUTHOR_DATE='2026-01-31T12:00:00+0000'
export GIT_COMMITTER_DATE='2026-01-31T12:00:00+0000'
git() { "$x" -l git -- "$@" < /dev/null; }
cd "$d/work" || exit 1
. "$file"
