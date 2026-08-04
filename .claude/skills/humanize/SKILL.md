---
name: humanize
description: Rewrites short-form public-facing copy (app store listings, pinned YouTube/Discord/Reddit comments, changelog notes, social posts, README blurbs) to strip out the statistical tells of AI-generated writing, so it reads like a person actually typed it. Use this whenever you ask to "humanize" text, write or polish a store listing, draft a pinned comment or announcement, or write any outward-facing copy, even if you don't say "AI" or "humanize" explicitly — e.g. "write the Play Store description" or "draft a comment to pin on the trailer." Not for long-form articles or technical docs (those need structure more than voice).
---

# Humanize

Short public copy (store listings, pinned comments, changelog notes) gets read by people
deciding whether to trust you in about two seconds. AI writing has a recognizable
statistical fingerprint: regression to the mean, generic positive language crowding out
specific, unusual, true detail. Readers pick up on it as insincere even when they can't
name why. This skill is a checklist for finding and removing that fingerprint.

**The goal is not word substitution.** Swapping "delve" for "explore" still leaves
AI-shaped sentences. Read each rewrite out loud. If it doesn't sound like something a
person would actually say to a friend, keep cutting.

## Before writing anything

Ask: what's the one true, specific thing this copy needs to say? A store listing needs to
say what the app does and why it's worth installing. A pinned comment needs to say one real
thing about the video. Write that first, plainly. Everything else in this checklist is
about not burying it.

## The checklist

### 1. Kill the AI vocabulary
Certain words are statistically overrepresented in LLM output regardless of topic: *delve,
boasts, crucial, underscore(s), testament, tapestry, robust, seamless, elevate, unlock,
showcase, leverage, foster, streamline, game-changer, cutting-edge*. Any one of these might
be a coincidence. Two or more in one paragraph is the tell.

> Before: "This app **boasts** a **seamless**, **robust** experience that **elevates** how
> you get things done."
> After: "This app gets out of your way so you can actually finish the thing."

### 2. Let things just *be*
AI avoids plain "is/are" and reaches for "serves as," "functions as," "represents." Plain
copulatives read as more confident and less like marketing copy, not less.

> Before: "This update **serves as** a major step forward in performance."
> After: "This update makes the app open twice as fast."

### 3. Cut negative parallelism
"Not just X, but Y" and "It's not X, it's Y" are AI's default move for adding emphasis
without adding information. If Y is true, just say Y.

> Before: "This isn't just a note-taking app — it's a whole new way to think."
> After: "It's a note-taking app that gets out of your way."

### 4. Watch for rule-of-three padding
Three adjectives or three short parallel phrases in a row ("fast, intuitive, and powerful")
is a formula for sounding comprehensive without saying much. If you can cut two of the
three and lose no information, do it.

> Before: "Fast, intuitive, and powerful — built for people who want it all."
> After: "Opens a page in under a second."

### 5. Don't puff up significance or legacy
AI inflates small things into milestones: "marks a pivotal moment," "reflects our ongoing
commitment to," "stands as a testament to." Real updates don't need to announce their own
importance. The feature speaks for itself, or it doesn't belong in the copy.

> Before: "This release **reflects our ongoing commitment to** accessibility."
> After: "Added a dyslexia-friendly font."

### 6. Drop vague attributions
"Industry reports show," "users have praised," "many people say": unless you're naming a
specific person, review, or number, this is filler pretending to be evidence. Either cite
something real or cut the claim.

> Before: "Users have praised the app's clean design."
> After: "4.8 stars, 1,200 reviews." *(only if actually true; don't invent a stat to
> replace a vague one)*

### 7. Em dashes: pick a house rule and write it down
Em dashes are one of the more commonly noticed AI tics, but whether to ban them outright is
your call, not a universal rule — put your own answer in `CLAUDE.md` (see this repo's
`CLAUDE.md.template`, "House style, by example") so it's consistent rather than
re-litigated every time. If you do ban them in public-facing copy, this is what the fix
looks like:

> Before: "Get things done faster — without losing the details — using this app."
> After: "Get things done faster without losing the details."

### 8. No bolded inline-header lists for short copy
"**Fast:** loads instantly. **Simple:** one-tap setup. **Free:** no catch." reads like a
slide deck, not a person talking. For anything under a few hundred words (which is almost
everything this skill applies to), write it as sentences.

### 9. No manufactured "despite challenges" arc
AI loves closing with a challenges-then-triumph beat, even for a changelog: "Despite early
hurdles, the team persevered to deliver..." Real updates just state what changed. If there
genuinely was a hard tradeoff worth mentioning, say the specific thing, not the shape of a
redemption story.

### 10. Strip assistant leftovers
Nothing you publish should sound like it's still talking to the person who prompted it:
"Let me know if you'd like any changes," "I hope this helps," "Feel free to reach out,"
"Would you like me to expand on this?" These are chatbot-to-user phrases, not copy. Delete
on sight.

## Quick self-check before shipping

Read the copy once more and ask:
- If I deleted every sentence that's true of almost any app/video/update, what's left?
  (That's usually the only part worth keeping.)
- Would I actually say this out loud to someone, in these words?
- Is there a plain, specific fact I could swap in for any vague claim of quality or
  importance?
- Any em dashes (if you've banned them), bolded three-item lists, or "not just X but Y"
  left? Cut them.

If the copy is now shorter and blunter than the first draft, that's usually a sign it
worked. AI inflates, humans compress.

## Make this yours

This checklist catches generic AI tells, but it can't know what *your* voice actually
sounds like — only you know that. The highest-leverage next step is to paste in a few
paragraphs you've genuinely written (an email, a forum post, a comment you left somewhere)
and ask your agent to name three specific, concrete traits of how you write: sentence
length, where you put jokes, what you never say, whether you contract words, what you
tend to lead with. Keep that list next to this file and point back to it before drafting
public copy. A checklist for removing AI tells plus a short, honest description of your
own voice will get you further than either one alone.
