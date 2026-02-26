# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Lobsters is a Ruby on Rails 8.0 community news/discussion site (like Hacker News). Ruby 4.0, MariaDB primary database, SQLite for cache and job queue (SolidQueue). The live site is at lobste.rs.

## Common Commands

### Development Setup
```sh
bin/setup                    # Install deps, prepare database
rails fake_data              # Generate sample data (login as test/test)
rails server                 # Start dev server at http://localhost:3000
```

### Testing & Quality
```sh
bundle exec rspec                                # Run test suite
bundle exec rspec spec/models/story_spec.rb      # Run a single spec file
bundle exec rspec spec/models/story_spec.rb:42   # Run a specific test by line
bundle exec standardrb --fix-unsafely            # Lint/format (StandardRB)
brakeman -q                                      # Security scan
```

### Full Build (matches CI)
```sh
bundle exec rspec && bundle exec standardrb --fix-unsafely && brakeman -q
```

### Makefile Shortcuts
```sh
make test    # rspec + brakeman
make lint    # standardrb --fix-unsafely
make all     # lint + test
```

### Docker
```sh
docker compose up --build        # Start MariaDB + Rails
docker compose run app bash      # Interactive shell
docker compose run app bin/setup # Setup DB in container
```

## Architecture

### Database
Multi-database setup: primary (MariaDB via Trilogy adapter), cache (SQLite/SolidCache), queue (SQLite/SolidQueue). Default dev credentials: root/localdev on 127.0.0.1:3306.

### Core Models
- **Story** — submitted links/text posts with voting, tagging, merging, and short IDs
- **Comment** — threaded comments with voting, flagging, and moderation
- **User** — accounts with `has_secure_password`, TOTP 2FA, OAuth (GitHub/Mastodon), typed_store settings
- **Tag/Category** — content classification; tags have hotness modifiers and can be privileged (mod-only)
- **Vote** — polymorphic voting for stories and comments with confidence-based ranking
- **Hat** — user badges granted by moderators, displayed on comments
- **Domain/Link/Origin** — tracks submitted URLs and their domains (domains can be banned)

### Moderation System
Controllers under `app/controllers/mod/` must inherit from `ModeratorController` (enforced by a custom RuboCop cop in `lib/custom_cops/inherits_moderator_controller.rb`). Moderation actions are logged to the `Moderation` model for an audit trail.

### Background Jobs
SolidQueue with SQLite. Recurring jobs configured in `config/recurring.yml`. Key jobs: notification delivery, webmention sending, email blocklist fetching, stats generation.

### Content Rendering
Markdown via CommonMark with custom processing. No JavaScript build chain — JS is minimal and optional.

### Key Routes
- `/s/:id` — story short ID
- `/c/:id` — comment short ID
- `/~:username` — user profile
- `/t/:tag` — tag filter
- `/domains/:id` — domain filter
- Feed views: `/`, `/newest`, `/active`, `/recent`, `/top`

## Testing Conventions

RSpec with FactoryBot. Tests live in `spec/`. Slow tests in `spec/slow/` are excluded from the default run. The project tests happy paths and complex logic rather than aiming for full coverage. Duplicate existing tests when getting started.

## Code Style

StandardRB handles all formatting (no custom Rubocop config tweaking). Custom cops are in `.custom_cops.yml`. The `.standard.yml` disables `Lint/UselessAssignment` globally.

## Design Philosophy

- Lean into Rails conventions over custom code
- Minimal dependencies; avoid adding external services
- No JSON/XML input parsers (security posture)
- JavaScript is optional — no JS build pipeline
- Present tense commit messages ("fix foo", not "fixed foo")
