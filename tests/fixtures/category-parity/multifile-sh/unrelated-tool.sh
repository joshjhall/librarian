#!/usr/bin/env bash
# Fixture: a sibling bash tool the entry does NOT source (#991).
#
# The bash analogue of ../multifile/unrelated_tool.py. Its slug must NOT be
# folded into the impl's set: a directory sweep would pick it up and invent a
# bash-only divergence, which is the first-attempt bug #772 records on the
# python side. check-ai-config/agnix-normalize.sh is the real instance.
emit_unrelated() {
    printf 'x\t1\t%s\tevidence\tHIGH\n' "cat-unrelated-tool"
}
