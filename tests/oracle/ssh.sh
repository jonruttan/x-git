#!/bin/sh
# tests/oracle/ssh.sh -- x-git over x-ssh, x at every hop.
#
# Usage: X=/path/to/x X_LANG_DIR=DIR/ sh tests/oracle/ssh.sh [PORT]
#
# DIR holds this tree as `git` and x-ssh as `ssh`.  x-ssh's server is
# started on 127.0.0.1:PORT for the run, with git-upload-pack and
# git-receive-pack on its PATH running x-git's own services, so a clone,
# a fetch and a push go x-git -> x-ssh's client -> x-ssh's server ->
# x-git, and git checks what lands:
#
#   clone   ssh://USER@127.0.0.1:PORT/SRC: the clone's log is the
#           source's, and fsck --strict passes
#   fetch   what the source grew since: origin/main moves to it
#   push    a commit made in the clone, to the bare source: its main is
#           the clone's, and fsck --strict passes there
#
# Every exchange has fresh ephemeral keys, so this is the live test the
# specs cannot replay; the specs check the command lines against git's
# through a stand-in ssh.
set -u
port=${1:-22233}
X=${X:-x}
: "${X_LANG_DIR:?a directory holding this tree as git and x-ssh as ssh}"
export X_LANG_DIR
fx=$(mktemp -d "${TMPDIR:-/tmp}/x-git-ssh-oracle.XXXXXX")
user=$(id -un)
fails=0
srvpid=

# The launcher pipes its program into an engine child, so the server's
# process is the launcher's child's child: the whole tree is stopped.
kill_tree() {
	[ -n "$1" ] || return 0
	for c in $(ps -axo pid,ppid | awk -v p="$1" '$2 == p { print $1 }'); do kill_tree "$c"; done
	kill "$1" 2>/dev/null
}
trap 'kill_tree "$srvpid"; rm -rf "$fx"' EXIT

ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

# The far side's git: x-git's services, found on the server's PATH.
mkdir -p "$fx/bin" "$fx/home/.ssh"
for s in upload-pack receive-pack; do
	printf '#!/bin/sh\nexec "%s" -l git -- %s "$@"\n' "$X" "$s" > "$fx/bin/git-$s"
	chmod +x "$fx/bin/git-$s"
done

# Keys: the host's from x-ssh's dropbearkey, the user's from ssh-keygen.
"$X" -l ssh -- dropbearkey -t ed25519 -f "$fx/hostkey" > /dev/null 2>&1
ssh-keygen -q -t ed25519 -N '' -C x-git-oracle -f "$fx/userkey"
cp "$fx/userkey.pub" "$fx/authorized_keys"

# This side's ssh, as git takes one in GIT_SSH: x-ssh's client.
printf '#!/bin/sh\nHOME="%s" exec "%s" -l ssh -- dbclient -y -i "%s" "$@"\n' "$fx/home" "$X" "$fx/userkey" > "$fx/ssh"
chmod +x "$fx/ssh"

PATH="$fx/bin:$PATH" "$X" -l ssh -- dropbear -F -E -r "$fx/hostkey" -p "127.0.0.1:$port" -D "$fx" > "$fx/server.log" 2>&1 &
srvpid=$!
i=0
while ! grep -q 'Not backgrounding' "$fx/server.log" 2>/dev/null && [ $i -lt 120 ]; do i=$((i + 1)); sleep 1; done
grep -q 'Not backgrounding' "$fx/server.log" || { cat "$fx/server.log"; echo "FAIL: the server did not start"; exit 1; }

# The source: a working repository, then bare, so a push can land.
git init -q -b main "$fx/work"
(cd "$fx/work" && printf 'one\n' > f && git add f && git -c user.name=A -c user.email=a@b.c commit -qm one \
	&& git -c user.name=A -c user.email=a@b.c tag -a v1 -m tagged)
git clone -q --bare "$fx/work" "$fx/src.git"
url="ssh://$user@127.0.0.1:$port$fx/src.git"
xgit() { GIT_SSH="$fx/ssh" "$X" -l git -- "$@"; }

if (cd "$fx" && xgit clone "$url" dst) > "$fx/clone.out" 2>&1 \
	&& [ "$(git -C "$fx/dst" log --format=%H main)" = "$(git -C "$fx/src.git" log --format=%H main)" ] \
	&& git -C "$fx/dst" fsck --strict > /dev/null 2>&1; then
	ok "clone -- the source's history, over x-ssh to x-git's upload-pack"
else
	cat "$fx/clone.out" "$fx/server.log"; bad "clone"
fi

(cd "$fx/work" && printf 'two\n' >> f && git -c user.name=A -c user.email=a@b.c commit -qam two && git push -q "$fx/src.git" main)
if (cd "$fx/dst" && xgit fetch) > "$fx/fetch.out" 2>&1 \
	&& [ "$(git -C "$fx/dst" rev-parse origin/main)" = "$(git -C "$fx/src.git" rev-parse main)" ] \
	&& git -C "$fx/dst" fsck --strict > /dev/null 2>&1; then
	ok "fetch -- origin/main moves to what the source grew"
else
	cat "$fx/fetch.out"; bad "fetch"
fi

(cd "$fx/dst" && git merge -q --ff-only origin/main && printf 'three\n' >> f && git -c user.name=A -c user.email=a@b.c commit -qam three)
if (cd "$fx/dst" && xgit push) > "$fx/push.out" 2>&1 \
	&& [ "$(git -C "$fx/src.git" rev-parse main)" = "$(git -C "$fx/dst" rev-parse HEAD)" ] \
	&& git -C "$fx/src.git" fsck --strict > /dev/null 2>&1; then
	ok "push -- the bare source's main is the clone's, through x-git's receive-pack"
else
	cat "$fx/push.out"; bad "push"
fi

[ "$fails" = 0 ] || { echo "$fails failed"; exit 1; }
echo "x-git over x-ssh: clone, fetch and push, x at every hop."
