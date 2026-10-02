# Claude Polecats & Codex Reviewer Pack

I use it the following way:

I add two folders to the my city:
- packs
- projects

Projects contains all the git repos for the city
Packs has my packs in it. In there, check out this pack as "mmlac"

In your city, refer the pack as follows:

```
[[rigs]]
name = "gascitysource"
prefix = "gct"
includes = ["./packs/mmlac"]
```

## Tests

Run `python3 -m unittest discover -s tests -v` from the pack directory.
The worktree tests use Git and `sh` in disposable local repositories. They do
not start agents or access a beads database.
