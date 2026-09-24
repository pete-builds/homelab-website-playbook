---
title: "Your first post: how to write the next one"
description: "How posts work on this site: one command to start one, a few settings at the top, then you just write. Delete this post when you have your own."
date: 2026-09-23
tags: [meta]
draft: false
---

This is an example post. Everything on this page came from one text file,
`src/content/posts/your-first-post.md`. Here's how to write the next one.

## Start a post

In the site's folder, run:

```sh
npm run new:post -- "What I learned building a shed"
```

That makes `src/content/posts/what-i-learned-building-a-shed.md`, with today's
date, marked as a **draft**. Drafts show up when you preview with
`npm run dev` and never on the live site, so an unfinished post can't go out by
accident. Or just ask Claude: *"start a post about building my shed"*.

## The settings at the top

Between the two `---` lines:

- `title`: the headline, 70 characters at most.
- `description`: one sentence for search results and link previews.
- `date`: written like 2026-09-23.
- `draft`: `true` while you're writing. Change it to `false` to publish.
- `tags` (optional): a list, like `[travel, food]`.
- `image` and `imageAlt` (optional): the picture shown when someone shares the
  post, like `/images/shed.jpg` for a file in `public/images/`, and a few words
  describing it.

If something up there is wrong, the build stops and names the file and the
setting, so a broken post never reaches the live site.

## Then write

Below the settings, write like you'd write an email. A blank line starts a new
paragraph. A few extras:

- `## A heading` starts a section. Use two `#`, never one: the title is
  already the page's main heading.
- `[words](https://example.com)` makes a link.
- A line starting with `- ` makes a list like this one.
- Pictures: put the file in `src/assets/` and write
  `![what the picture shows](../../assets/shed.jpg)`. The site resizes it and
  gives it a new name whenever it changes, so nobody sees an old copy.

## Publish

Set `draft: false`, save, commit, and deploy. When you have a post of your own,
delete this file.
