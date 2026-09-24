// The blog's rules. Every post in src/content/posts/ is checked against this
// when the site builds, and a post that breaks a rule stops the build with a
// message naming the file and the field. Start a new post with
//   npm run new:post -- "Your title"
import { defineCollection } from 'astro:content';
import { glob } from 'astro/loaders';
import { z } from 'astro/zod';
import { isSafeImage, IMAGE_HINT } from './lib/safe-image.js';

const posts = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/posts' }),
  schema: z
    // strictObject: a misspelled field (drafts: true, Title: ...) fails the
    // build instead of being quietly ignored and publishing the post.
    .strictObject({
      title: z
        .string({ error: 'required, in quotes' })
        .trim()
        .min(1, { error: 'required' })
        .max(70, { error: 'at most 70 characters; search results cut off longer titles' }),
      description: z
        .string({ error: 'required: one sentence for search results and link previews' })
        .trim()
        .min(1, { error: 'required: one sentence for search results and link previews' })
        .max(160, { error: 'at most 160 characters; search results cut off longer descriptions' }),
      date: z.coerce.date({ error: 'write the date as YYYY-MM-DD, like 2026-09-23' }),
      tags: z.array(z.string().min(1), { error: 'a list, like [travel, food]' }).optional(),
      draft: z.boolean({ error: 'true or false' }).default(false),
      // The picture shown when someone shares the post. Not shown on the page;
      // put pictures in the post itself with markdown.
      image: z.string().refine(isSafeImage, { error: IMAGE_HINT }).optional(),
      imageAlt: z.string().trim().min(1, { error: 'describe the picture in a few words' }).optional(),
    })
    .refine((post) => !post.image || post.imageAlt, {
      path: ['imageAlt'],
      error: 'required when image is set: describe the picture for people who cannot see it',
    })
    .refine((post) => post.draft || !/^TODO\b/i.test(post.description), {
      path: ['description'],
      error: 'still the TODO placeholder; write one sentence before setting draft: false',
    }),
});

export const collections = { posts };
