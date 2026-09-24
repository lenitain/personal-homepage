# yazi-homepage

A personal homepage laid out like a code editor: a file tree on the left, the article on the right.

## Stack

- SvelteKit + TypeScript
- SVG filters for chalk-on-blackboard typography
- Everforest dark medium color scheme
- Pure frontend — no backend required

## Features

- Collapsible file tree over the real `content/` directory — every page you can read is a `.md` file in there
- File-manager keyboard: `↑`/`↓` select and the article shows up immediately, `←`/`→` fold and unfold folders, typing a letter jumps to a matching entry — no key legend needed
- Markdown rendering with chalk-on-blackboard aesthetic
- Sidebar folds away to a 22px rail, and remembers which folders you had open
