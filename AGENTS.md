# Ithibati — notes for whatever is editing this

The project's own rules are in [CONTRIBUTING.md](CONTRIBUTING.md): the architecture it may not
violate, and the conventions its code and its prose are held to. They belong to the project
rather than to any one tool, and they apply to anybody editing this repository. Read them first.

What follows is true only of this checkout.

## The tracker is not in the repository

`.beans/` and `.beans.yml` are gitignored here. The tracker is a personal tool in a format
nobody else reads, and this library ships to strangers. So **do not commit bean files, and do
not add them back** — and say so rather than assuming a bean is safe, because the backlog lives
on one machine and `git push` does not back it up.

**Bean IDs (`ithibati-xxxx`) never appear in `lib/`, `test/`, `docs/`, `priv/` or `README.md`.**
They belong in the beans and in this file, which live with the tracker. Nothing in this
repository can resolve one, and a dead ID looks authoritative while sending the next reader
nowhere. Write the *why* out and leave the reference off. `Ithibati.Credo.NoBeanIds` enforces it.
