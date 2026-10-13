import { build } from "esbuild";
import { mkdir, copyFile } from "node:fs/promises";
await mkdir("dist",{recursive:true});
await build({entryPoints:["src/App.jsx"],bundle:true,minify:true,format:"esm",jsx:"automatic",define:{"process.env.NODE_ENV":'"production"'},outfile:"dist/client.js",legalComments:"linked"});
await Promise.all(["index.html","styles.css"].map(name=>copyFile(name,"dist/"+name)));
