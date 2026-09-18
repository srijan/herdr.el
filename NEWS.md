# News

Breaking changes and anything else worth knowing before upgrading, newest
first. Ordinary fixes are in the git log.

## Unreleased

**`herdr-state-pane-status` is gone — call `herdr-pane-status`.**

It existed to project a client-computed `done` over whatever the pane record
said. herdr computes `done` itself and puts it on the wire, so there is nothing
left to project and no reason for a second accessor. The replacement reads the
pane alone; the state argument has no remaining purpose.

```elisp
(herdr-state-pane-status state pane)  ; before
(herdr-pane-status pane)              ; after
```

**`herdr-pane-directory` is gone — call `herdr-pane-directory-name`.**

The two differed only in that `herdr-pane-directory` asked the filesystem
whether the directory existed. That question is wrong for a pane on another
machine, because the filesystem it asks is not the one the pane is on — which
is why nothing in the package called it. `herdr-pane-directory-name` returns
the same path unchecked. Apply `file-directory-p` yourself if you want the
check and you know the pane is local.
