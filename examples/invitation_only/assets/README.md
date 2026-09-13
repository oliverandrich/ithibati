# Why there is a package.json here

Nothing in this directory needs npm. The file exists to stop Node's resolution walking up out of
this example and into the library's own `package.json`, which declares `"type": "module"` so that a
consumer can `import … from "ithibati"`.

That declaration is right for the library and wrong for Phoenix's vendored `topbar.js`, which is
CommonJS. Without this file esbuild treats it as an ES module and the build fails with *No matching
export for import "default"* — an error whose cause is three directories above the file it names.

A real consuming application never sees this, because it does not live inside the library.
