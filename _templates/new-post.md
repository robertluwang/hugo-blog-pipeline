<%*
const title = await tp.system.prompt("Post title");
if (!title) return;
const tags = await tp.system.prompt("Tags (comma-separated, or leave empty)");
const slug = title.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
const date = tp.date.now("YYYY-MM-DD");
const datetime = tp.date.now("YYYY-MM-DDTHH:mm:ssZ");
const folder = `content/posts/${date}-${slug}`;

// Format tags
let tagLine = "tags = []";
if (tags && tags.trim()) {
    const tagArray = tags.split(',').map(t => `'${t.trim()}'`).join(', ');
    tagLine = `tags = [${tagArray}]`;
}

const content = `+++
date = '${datetime}'
draft = false
title = '${title}'
${tagLine}

[params.cover]
  image = "banner.png"
  alt = "${title}"
  relative = true
+++

`;

await app.vault.createFolder(folder);
await app.vault.create(`${folder}/index.md`, content);
await app.workspace.openLinkText(`${folder}/index.md`, "");

// Remove the temporary note that triggered this template
if (tp.file.title !== "index") {
    await app.vault.trash(tp.file);
}
%>
