# Marketing site to 0.9.0 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Correct the two claims on the marketing site that no longer match the tool, and surface the host-lifecycle commands 0.9.0 adds, without turning a landing page into documentation.

**Architecture:** A Rails app whose content is two ERB views — `app/views/pages/home.html.erb` and `app/views/pages/pro.html.erb`. There is no CMS and no content model: copy is edited in the ERB directly. Tailwind utility classes, a `copper`/`mint`/`surface` palette, and a feature grid of repeated `div.p-6.md:p-8.bg-surface-high` cards.

**Tech Stack:** Rails, ERB, Tailwind. `spec/` holds only `rails_helper.rb` and `spec_helper.rb` — there are no examples, so nothing here is test-guarded and every change is verified by reading the rendered page.

**Source of truth:** the gem source at `/home/tsultrim/Code/WaConstellation/WaSystems/OdysseusProject/Odysseus` at 0.9.0, and its `odysseus-cli/README.md`.

**Repo:** `/home/tsultrim/Code/WaConstellation/WaSystems/OdysseusProject/odysseus-site/rails-site`

## Global Constraints

- **The working tree has uncommitted changes** (`Dockerfile`, `Gemfile`, `Gemfile.lock`, `app/controllers/pages_controller.rb`, `bin/docker-entrypoint`, and others). Never run `git checkout`, `git stash`, `git reset` or `git clean`. `git add` only the view files your task names.
- This is a **landing page, not documentation**. Every change is a sentence or a heading. If a change wants a paragraph, it belongs on the doc site instead — say so in your report rather than writing it here.
- Do not restyle anything. No new Tailwind classes, no layout changes, no new sections unless a task says to add one. Copy only.
- Claims must be true of 0.9.0 as shipped. Check the gem source before writing, and name the file you checked in your report.
- Keep the existing voice: short, concrete, no exclamation marks, no "blazing fast".

---

### Task 1: "Accessories" is a name the tool stopped using

**Files:**
- Modify: `app/views/pages/home.html.erb` (feature card at ~line 102)

- [ ] **Step 1: Confirm the rename before writing**

`odysseus-core/lib/odysseus/config/parser.rb` accepts both `dependencies:` and the older `accessories:`, and treats both being present as an error. The rename landed in 0.4.4. Confirm this yourself rather than taking it from this plan.

- [ ] **Step 2: Retitle the card and its copy**

Current:

```erb
<h3 class="font-headline text-xl font-bold mb-3">Roles &amp; accessories</h3>
<p class="text-text-muted leading-relaxed">Deploy web servers, background workers, databases, and Redis from one config. Each role can have different resources and commands.</p>
```

Becomes "Roles &amp; dependencies", with copy that keeps the same shape and length. Do not mention the deprecation here — a landing page is the wrong place for a migration note, and the doc site carries it.

- [ ] **Step 3: Commit**

```bash
git add app/views/pages/home.html.erb
git commit -m "Say dependencies, which is what the tool calls them"
```

---

### Task 2: The Quick Start teaches the shortcut as the default

**Files:**
- Modify: `app/views/pages/home.html.erb` (terminal block at ~line 245-258)

**Interfaces:**
- Consumes: nothing. Produces: nothing. Self-contained copy change.

- [ ] **Step 1: Read why this matters**

`odysseus-cli/README.md`, "Naming the version". Deploying from a clean git repository tags the image with the commit and records it in the deploy log, so `rollback --list` can say what code a version was. `--image TAG` skips all of that: no commit is recorded, and nothing stops a tag being reused, which leaves two deploy-log entries odysseus cannot tell apart. It is the right tool for trying something out and the wrong default to teach.

The block currently leads with `odysseus deploy --build --image v1.0.0` — the shortcut, as the only example shown.

- [ ] **Step 2: Lead with the git-commit route**

Keep the block's structure and classes exactly; change the commands so the primary line is `odysseus deploy --build`, with a dim comment line noting the version comes from the commit, and keep `--image` visible as the quick way for anything outside a git repository. The existing `text-text-dim text-xs` comment style is already used in this block — reuse it rather than inventing one.

The success line ("Deployed. Traffic live on v1.0.0.") must change to match whatever the primary command now produces, or it will describe a run that did not happen.

- [ ] **Step 3: Commit**

---

### Task 3: "Minimal server requirements" is now more true, not less

**Files:**
- Modify: `app/views/pages/home.html.erb` (feature card at ~line 97)

- [ ] **Step 1: Verify both halves**

Deploys never gate on distro — confirm there is no distro check anywhere in `odysseus-core/lib/odysseus/deployer/`. `setup` does gate, to Ubuntu 24.04/26.04, in `odysseus-core/lib/odysseus/setup/preparer.rb`.

- [ ] **Step 2: Rewrite the card**

Current copy: "Just Docker and SSH access. Caddy is deployed as a managed container automatically — no manual installation."

It should now say Docker and SSH, that `odysseus setup` can install Docker on a fresh Ubuntu host, and keep the Caddy sentence, which is still true. Do not imply Ubuntu is required to deploy — it is required only by `setup`.

- [ ] **Step 3: Commit**

---

### Task 4: Give setup and doctor one line each

**Files:**
- Modify: `app/views/pages/home.html.erb` (Features grid, after the "Minimal server requirements" card)

- [ ] **Step 1: Add one feature card**

One card, matching the existing markup exactly:

```erb
<div class="p-6 md:p-8 bg-surface-high rounded-lg hover:bg-surface-highest transition-all duration-300">
  <h3 class="font-headline text-xl font-bold mb-3">Host setup and diagnosis</h3>
  <p class="text-text-muted leading-relaxed">...</p>
</div>
```

The copy covers both commands in two sentences: `setup` prepares a fresh Ubuntu host — deploy user, docker group, your key, Docker itself — for getting one host going; `doctor` reads a host back and tells you whether odysseus can use it, however it was prepared. Include that provisioning at scale belongs to OpenTofu or equivalent, in a clause rather than a sentence: it is the honest framing and it is short.

- [ ] **Step 2: Check the grid still balances**

The Features grid has an even number of cards today. Adding one makes it odd — check how the grid wraps at `md` and `lg` and say in your report whether the last row now has a gap. If it does, that is a design decision for a human, not something to fix by padding the copy or dropping a card.

- [ ] **Step 3: Commit**

---

## Deliberately not in this plan

- **The Pro page** (`app/views/pages/pro.html.erb`). Nothing in 0.9.0 changes what it claims.
- **Version numbers.** The site hardcodes none, which is why nothing here has to change per release. Do not add any.
- **A commands list, a features table, or anything resembling reference material.** That is the doc site's job, and the two drifting apart is how this site got stale.
- **Restyling, palette changes, new sections.** Out of scope even where tempting.

## Definition of done

- `grep -rn -i "accessor" app/views/` returns nothing.
- The Quick Start's first deploy command is the git-commit route, and its success line matches it.
- No claim on the page requires Ubuntu to deploy.
- `bin/rails runner 'ActionController::Base.new.render_to_string(template: "pages/home")'` renders without raising, or the app boots and `/` returns 200 — the views have no test coverage, so one of these is the only check there is.
- The uncommitted `Dockerfile`, `Gemfile`, `Gemfile.lock`, `pages_controller.rb` and `bin/docker-entrypoint` changes are still uncommitted and unmodified.
