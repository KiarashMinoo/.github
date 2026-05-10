#!/usr/bin/env python3
"""
Release notes generator for CHANGELOG.md

Implements .github/prompts/release-notes.prompt.md:
- Incremental state tracking (.github/release-notes.state.json)
- Tag-based ranges with GitHub compare links
- Conventional Commit grouping (feat, fix, perf, refactor, docs, chore, build, ci, test, style, revert, deps, other)
- C/C++-aware diff analysis (API/ABI hints, function signatures, build system changes)
- Path filtering (include/exclude globs)
- Diff content modes (diff-hunks, added-lines, removed-lines, api-changes)
- Managed block updates or full overwrite (--resetAll)
"""
import argparse
import fnmatch
import json
import os
import re
import shlex
import subprocess
import sys
from datetime import datetime

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))

# Defaults from prompt
DEFAULT_TAG_FILTER = r'^v?\d+\.(Q\d+|\d+)\.\d+$'  # Matches v1.2.3 or v2025.Q4.81
DEFAULT_PATH_INCLUDE = r'**/*.{h,hpp,hxx,hh,c,cc,cpp,cxx,cs},**/*.{csproj,sln},CMakeLists.txt,**/*.cmake,conanfile.*,vcpkg.json,**/*.bazel,WORKSPACE,.clang-format,.clang-tidy'
CPP_EXT = {'.h', '.hpp', '.hh', '.hxx', '.c', '.cc', '.cpp', '.cxx'}
CSHARP_EXT = {'.cs'}
BUILD_FILES = {'CMakeLists.txt', 'conanfile.txt', 'conanfile.py', 'vcpkg.json', 'WORKSPACE', '.clang-format', '.clang-tidy', '.sln'}
COMMIT_TYPES = ['feat', 'fix', 'perf', 'refactor', 'docs', 'chore', 'build', 'ci', 'test', 'style', 'revert', 'deps', 'other']

def run(cmd, cwd=ROOT):
    """Run shell command and return (returncode, stdout)"""
    try:
        out = subprocess.check_output(cmd, cwd=cwd, shell=True, stderr=subprocess.DEVNULL, text=True)
        return 0, out
    except subprocess.CalledProcessError as e:
        return e.returncode, e.output if e.output else ''

def git_head_sha():
    rc, out = run('git rev-parse HEAD')
    return out.strip() if rc == 0 else None

def git_branch():
    rc, out = run('git rev-parse --abbrev-ref HEAD')
    return out.strip() if rc == 0 else None

def load_state(path):
    if not os.path.exists(path):
        return None
    try:
        with open(path, 'r', encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return None

def save_state(path, data):
    ddir = os.path.dirname(path)
    if ddir and not os.path.exists(ddir):
        os.makedirs(ddir, exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2)

def parse_globs(globs_str):
    """Parse comma-separated glob patterns"""
    if not globs_str:
        return []
    return [g.strip() for g in globs_str.split(',') if g.strip()]

def match_path(path, include_globs, exclude_globs):
    """Check if path matches include and not exclude patterns"""
    if exclude_globs and any(fnmatch.fnmatch(path, pat) for pat in exclude_globs):
        return False
    if not include_globs:
        return True
    return any(fnmatch.fnmatch(path, pat) for pat in include_globs)

def list_tags(tag_filter_re):
    """List tags matching filter, newest to oldest (descending)"""
    # Don't fetch in local dev; only in CI
    # run('git fetch --tags --force')
    # Use simpler command for cross-platform compatibility (descending order)
    rc, out = run('git tag -l --sort=-creatordate')
    if rc != 0:
        return []
    tags = []
    for line in out.splitlines():
        t = line.strip()
        if not t:
            continue
        if tag_filter_re.match(t):
            # Get date for this tag
            rc2, date_out = run(f'git log -1 --format=%ci {t}')
            date = date_out.split()[0] if rc2 == 0 else ''
            tags.append((t, date))
    return tags

def get_commit_detail(sha, diff_context=0, file_limit=0, hunk_limit=2, lines_per_hunk=40, lines_per_commit=300):
    """Get commit metadata, files, and diff hunks"""
    # Metadata
    fmt = '%H%x09%h%x09%ad%x09%s%x09%an%x09%ae'
    rc, out = run(f"git show --no-patch --date=short --pretty=format:'{fmt}' {sha}")
    if rc != 0:
        return None
    parts = out.strip().split('\t')
    if len(parts) < 6:
        return None
    
    commit = {
        'sha': parts[0],
        'short': parts[1],
        'date': parts[2],
        'subject': parts[3],
        'author': parts[4],
        'email': parts[5],
        'files': [],
        'hunks': []
    }
    
    # Files
    rc, out = run(f"git show --name-status --no-patch --pretty=format:'' {sha}")
    if rc == 0:
        for line in out.splitlines():
            if not line.strip():
                continue
            # Format: M\tpath or A\tpath
            parts = line.split('\t')
            if len(parts) >= 2:
                commit['files'].append({'status': parts[0], 'path': parts[1]})
    
    # Diff hunks
    rc, out = run(f"git show --unified={diff_context} --pretty=format:'' {sha}")
    if rc == 0:
        hunks = parse_diff_hunks(out, hunk_limit, lines_per_hunk, lines_per_commit)
        commit['hunks'] = hunks
    
    return commit

def parse_diff_hunks(diff_output, hunk_limit, lines_per_hunk, lines_per_commit):
    """Parse diff output into structured hunks"""
    hunks = []
    current_file = None
    current_hunk = None
    total_lines = 0
    
    for line in diff_output.splitlines():
        if total_lines >= lines_per_commit:
            break
            
        if line.startswith('diff --git'):
            # New file
            if current_hunk:
                hunks.append(current_hunk)
                current_hunk = None
            current_file = line.split(' b/')[-1] if ' b/' in line else None
            
        elif line.startswith('@@') and current_file:
            # New hunk
            if current_hunk:
                hunks.append(current_hunk)
            if hunk_limit > 0 and len([h for h in hunks if h['file'] == current_file]) >= hunk_limit:
                current_hunk = None
                continue
            current_hunk = {
                'file': current_file,
                'header': line,
                'lines': []
            }
            
        elif current_hunk and (line.startswith('+') or line.startswith('-') or line.startswith(' ')):
            if lines_per_hunk > 0 and len(current_hunk['lines']) >= lines_per_hunk:
                continue
            current_hunk['lines'].append(line)
            total_lines += 1
    
    if current_hunk:
        hunks.append(current_hunk)
    
    return hunks

def analyze_cpp_api_changes(commit):
    """Detect C/C++ API/ABI changes from hunks"""
    hints = []

    for hunk in commit.get('hunks', []):
        file_path = hunk['file']
        ext = os.path.splitext(file_path)[1]
        is_header = ext in CPP_EXT

        if not is_header:
            continue

        added_lines = [l[1:] for l in hunk['lines'] if l.startswith('+') and not l.startswith('+++')]
        removed_lines = [l[1:] for l in hunk['lines'] if l.startswith('-') and not l.startswith('---')]

        # Function signature detection
        func_pattern = re.compile(r'^\s*[\w:\*\&\s<>,~]+\s+(\w+)\s*\([^)]*\)\s*(const)?\s*(noexcept)?\s*[;{]')

        for line in added_lines:
            m = func_pattern.match(line)
            if m:
                hints.append(f"API: Added function `{m.group(1)}` in {file_path}")
                break

        for line in removed_lines:
            m = func_pattern.match(line)
            if m:
                hints.append(f"API: Removed function `{m.group(1)}` from {file_path}")
                break

        # Class/struct detection
        class_pattern = re.compile(r'^\s*(class|struct)\s+(\w+)')
        for line in added_lines:
            m = class_pattern.match(line)
            if m:
                hints.append(f"API: Added {m.group(1)} `{m.group(2)}` in {file_path}")
                break

    # Build system changes
    build_files = [f['path'] for f in commit.get('files', []) if os.path.basename(f['path']) in BUILD_FILES or f['path'].endswith('.cmake')]
    if build_files:
        hints.append(f"Build: Modified {', '.join(build_files[:3])}")

    return hints


def analyze_csharp_api_changes(commit):
    """Detect C# public API changes from hunks"""
    hints = []

    for hunk in commit.get('hunks', []):
        file_path = hunk['file']
        ext = os.path.splitext(file_path)[1]
        is_cs = ext in CSHARP_EXT

        if not is_cs:
            continue

        added_lines = [l[1:].strip() for l in hunk['lines'] if l.startswith('+') and not l.startswith('+++')]
        removed_lines = [l[1:].strip() for l in hunk['lines'] if l.startswith('-') and not l.startswith('---')]

        # Method/property/class detection
        # public [modifier] return_type Name(...) or public [modifier] Type Name { get; set; }
        method_pattern = re.compile(r'^(public|internal)\s+(static\s+)?[\w\<\>\[\],\s\.?]+\s+(\w+)\s*\([^)]*\)')
        prop_pattern = re.compile(r'^(public|internal)\s+[\w\<\>\[\],\s\.?]+\s+(\w+)\s*\{')
        class_pattern = re.compile(r'^(public|internal)\s+(class|struct|interface)\s+(\w+)')

        for line in added_lines:
            m = method_pattern.match(line)
            if m:
                hints.append(f"API: Added {m.group(1)} method `{m.group(3)}` in {file_path}")
                break
            m = prop_pattern.match(line)
            if m:
                hints.append(f"API: Added property `{m.group(2)}` in {file_path}")
                break
            m = class_pattern.match(line)
            if m:
                hints.append(f"API: Added {m.group(2)} `{m.group(3)}` in {file_path}")
                break

        for line in removed_lines:
            m = method_pattern.match(line)
            if m:
                hints.append(f"API: Removed {m.group(1)} method `{m.group(3)}` from {file_path}")
                break
            m = prop_pattern.match(line)
            if m:
                hints.append(f"API: Removed property `{m.group(2)}` from {file_path}")
                break
            m = class_pattern.match(line)
            if m:
                hints.append(f"API: Removed {m.group(2)} `{m.group(3)}` from {file_path}")
                break

    # Project/build system changes (.csproj, .sln)
    build_files = [f['path'] for f in commit.get('files', []) if f['path'].endswith('.csproj') or os.path.basename(f['path']) in BUILD_FILES]
    if build_files:
        hints.append(f"Build: Modified {', '.join(build_files[:3])}")

    return hints

def group_commits(commits):
    """Group commits by conventional commit type"""
    groups = {t: [] for t in COMMIT_TYPES}
    
    for c in commits:
        subject = c['subject']
        # Match type(scope): or type:
        m = re.match(r'^(\w+)(?:\([^)]*\))?:\s*', subject)
        commit_type = m.group(1).lower() if m and m.group(1).lower() in COMMIT_TYPES else 'other'
        groups[commit_type].append(c)
    
    return [(t, groups[t]) for t in COMMIT_TYPES if groups[t]]

def escape_md(text):
    """Escape markdown special characters"""
    return text.replace('_', r'\_').replace('*', r'\*').replace('[', r'\[').replace(']', r'\]')

def render_commit_line(commit, include_files, include_snippets, snippet_limit, contents_mode, api_hints):
    """Render a single commit bullet"""
    line = f"- {escape_md(commit['subject'])} ([`{commit['short']}`](https://github.com/{{owner}}/{{repo}}/commit/{commit['sha']}))"
    
    details = []
    
    # API hints
    if api_hints:
        details.extend([f"  - {h}" for h in api_hints[:2]])
    
    # Files
    if include_files and commit.get('files'):
        files_str = ', '.join([f"`{f['path']}`" for f in commit['files'][:5]])
        if len(commit['files']) > 5:
            files_str += f" _(+{len(commit['files'])-5} more)_"
        details.append(f"  - Files: {files_str}")
    
    # Snippets
    if include_snippets and commit.get('hunks') and contents_mode in ['diff-hunks', 'added-lines']:
        snippet_lines = []
        for hunk in commit['hunks'][:2]:
            if contents_mode == 'added-lines':
                snippet_lines.extend([l for l in hunk['lines'] if l.startswith('+')])
            else:
                snippet_lines.extend(hunk['lines'])
        
        if snippet_lines:
            snippet = '\n'.join(snippet_lines[:10])
            if len(snippet) > snippet_limit:
                snippet = snippet[:snippet_limit] + '...'
            details.append(f"  ```diff\n  {snippet}\n  ```")
    
    if details:
        line += '\n' + '\n'.join(details)
    
    return line

def render_section(title, commits, repo_owner, repo_name, max_highlights, include_files, include_snippets, 
                   snippet_limit, contents_mode, fold_empty, language_mode='auto'):
    """Render a release section"""
    if not commits and fold_empty:
        return ''
    
    lines = [f'## {title}\n']
    
    if not commits:
        lines.append('_No changes in this release._\n')
        return '\n'.join(lines)
    
    grouped = group_commits(commits)
    
    for commit_type, items in grouped:
        lines.append(f'### {commit_type.title()}\n')
        
        shown = items[:max_highlights] if max_highlights > 0 else items
        for c in shown:
            # Determine API hints depending on requested language mode
            api_hints = []
            if contents_mode == 'api-changes':
                if language_mode == 'cpp':
                    api_hints = analyze_cpp_api_changes(c)
                elif language_mode == 'csharp':
                    api_hints = analyze_csharp_api_changes(c)
                else:
                    # auto-detect from files in commit
                    files = [f.get('path','') for f in c.get('files', [])]
                    if any(os.path.splitext(p)[1] in CSHARP_EXT for p in files):
                        api_hints = analyze_csharp_api_changes(c)
                    elif any(os.path.splitext(p)[1] in CPP_EXT for p in files):
                        api_hints = analyze_cpp_api_changes(c)
                    else:
                        api_hints = []

            commit_line = render_commit_line(c, include_files, include_snippets, snippet_limit, contents_mode, api_hints)
            # Replace placeholders
            commit_line = commit_line.replace('{owner}', repo_owner).replace('{repo}', repo_name)
            lines.append(commit_line)
        
        if max_highlights > 0 and len(items) > max_highlights:
            lines.append(f'- _...and {len(items) - max_highlights} more commits_\n')
        
        lines.append('')
    
    return '\n'.join(lines)

def build_changelog(ranges, repo_owner, repo_name, args):
    """Build complete changelog from ranges"""
    parts = []
    parts.append(f'# {args.title}\n')
    parts.append('All notable changes to this project are documented in this file.\n')
    parts.append('The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).\n')
    
    for label, range_spec, compare_url in ranges:
        # Collect commits in range
        commits = []
        fmt = '%H%x09%h%x09%ad%x09%s%x09%an%x09%ae'
        rc, out = run(f"git log --date=short --pretty=format:'{fmt}' {shlex.quote(range_spec)} --")
        
        if rc == 0:
            for line in out.splitlines():
                if not line.strip():
                    continue
                parts_list = line.split('\t')
                if len(parts_list) >= 6:
                    commit = {
                        'sha': parts_list[0],
                        'short': parts_list[1],
                        'date': parts_list[2],
                        'subject': parts_list[3],
                        'author': parts_list[4],
                        'email': parts_list[5],
                        'files': [],
                        'hunks': []
                    }
                    
                    # Get detailed info for first N commits
                    if len(commits) < args.maxHighlights * 3:  # Get a bit more than we'll show
                        detail = get_commit_detail(commit['sha'], args.diffContext, args.fileLimit, 
                                                   args.hunkLimit, args.linesPerHunk, args.linesPerCommit)
                        if detail:
                            commit = detail
                    
                    commits.append(commit)
        
        # Filter by path
        if args.pathInclude or args.pathExclude:
            include_globs = parse_globs(args.pathInclude)
            exclude_globs = parse_globs(args.pathExclude)
            filtered = []
            for c in commits:
                if any(match_path(f['path'], include_globs, exclude_globs) for f in c.get('files', [])):
                    filtered.append(c)
                elif not c.get('files'):  # Keep commits with no file info
                    filtered.append(c)
            commits = filtered
        
        # Render section
        section_title = f'{label}'
        if compare_url:
            section_title = f'[{label}]({compare_url})'

        section = render_section(section_title, commits, repo_owner, repo_name, args.maxHighlights,
                               args.includeFiles, args.includeSnippets, args.snippetLimit,
                               args.contentsMode, args.foldEmpty, args.languageMode)
        if section:
            parts.append(section)
    
    return '\n'.join(parts)

def update_managed_block(output_path, content, reset_all):
    """Update managed block in output file or overwrite"""
    begin = '<!-- BEGIN AUTO-RELEASE-NOTES -->'
    end = '<!-- END AUTO-RELEASE-NOTES -->'
    block = f"{begin}\n{content}\n{end}\n"
    
    if reset_all or not os.path.exists(output_path):
        # Full overwrite
        with open(output_path, 'w', encoding='utf-8') as f:
            f.write(block)
    else:
        # Update managed block
        with open(output_path, 'r', encoding='utf-8') as f:
            old = f.read()
        
        if begin in old and end in old:
            pre = old.split(begin)[0]
            post = old.split(end, 1)[1] if end in old else ''
            new = pre + block + post
        else:
            # Append
            new = old + '\n' + block
        
        with open(output_path, 'w', encoding='utf-8') as f:
            f.write(new)


def main():
    ap = argparse.ArgumentParser(description='Generate CHANGELOG.md from git tags and commits')
    
    # Core inputs
    ap.add_argument('--tagFilter', default=DEFAULT_TAG_FILTER, help='Regex pattern for tag filtering')
    ap.add_argument('--output', default='CHANGELOG.md', help='Output file path')
    ap.add_argument('--repoOwner', default='KiarashMinoo', help='GitHub repo owner')
    ap.add_argument('--repoName', default='LicenseManager', help='GitHub repo name')
    ap.add_argument('--dateFormat', default='yyyy-MM-dd', help='Date format (not yet used)')
    ap.add_argument('--title', default='Changelog', help='Document title')
    ap.add_argument('--includeUnreleased', type=bool, default=True, help='Include unreleased section')
    ap.add_argument('--resetAll', action='store_true', help='Rebuild from scratch (overwrite file)')
    ap.add_argument('--refresh', action='store_true', help='Ignore state and recompute from tags')
    ap.add_argument('--state', default='.github/release-notes.state.json', help='State file path')
    
    # Scope & presentation
    ap.add_argument('--summaryStyle', choices=['concise', 'standard', 'detailed'], default='standard')
    ap.add_argument('--maxHighlights', type=int, default=6, help='Max commits per type section')
    ap.add_argument('--maxBulletsPerSection', type=int, default=0, help='Max bullets per section (0=unlimited)')
    ap.add_argument('--includeFiles', type=bool, default=True, help='Include file lists')
    ap.add_argument('--includeSnippets', type=bool, default=False, help='Include code snippets')
    ap.add_argument('--snippetLimit', type=int, default=320, help='Max chars per snippet')
    
    # Diff & analysis
    ap.add_argument('--diffContext', type=int, default=0, help='Diff context lines')
    ap.add_argument('--fileLimit', type=int, default=0, help='Max files per commit (0=unlimited)')
    ap.add_argument('--hunkLimit', type=int, default=2, help='Max hunks per file')
    ap.add_argument('--linesPerHunk', type=int, default=40, help='Max lines per hunk')
    ap.add_argument('--linesPerCommit', type=int, default=300, help='Max total diff lines per commit')
    ap.add_argument('--pathInclude', default=DEFAULT_PATH_INCLUDE, help='Include path globs (comma-separated)')
    ap.add_argument('--pathExclude', default='', help='Exclude path globs (comma-separated)')
    ap.add_argument('--skipTypes', default='', help='Skip commit types (comma-separated)')
    ap.add_argument('--foldEmpty', type=bool, default=True, help='Fold empty sections')
    
    # Contents mode
    ap.add_argument('--includeContents', type=bool, default=True, help='Include diff contents')
    ap.add_argument('--contentsMode', choices=['diff-hunks', 'added-lines', 'removed-lines', 'api-changes'], 
                   default='api-changes', help='Content analysis mode')
    ap.add_argument('--languageMode', choices=['auto', 'cpp', 'csharp'], default='cpp', help='Language mode for analysis')
    
    args = ap.parse_args()
    
    os.chdir(ROOT)
    
    # Step 1: Determine start point
    head = git_head_sha()
    branch = git_branch()
    if head is None:
        print('ERROR: git HEAD not found; aborting', file=sys.stderr)
        sys.exit(1)
    
    tag_filter_re = re.compile(args.tagFilter)
    
    state = None
    if args.resetAll:
        if os.path.exists(args.state):
            os.remove(args.state)
    elif not args.refresh:
        state = load_state(args.state)
    
    start_sha = None
    mode = 'full'
    
    if state and state.get('lastProcessedSha') and state.get('branch') == branch:
        last = state['lastProcessedSha']
        # Check if ancestor
        rc, _ = run(f'git merge-base --is-ancestor {last} {head}')
        if rc == 0:
            start_sha = last
            if start_sha != head:
                mode = 'incremental'
            else:
                mode = 'up-to-date'
    
    # Step 2: Collect tags & ranges
    ranges = []
    
    if mode == 'incremental':
        # Only unreleased
        ranges.append(('Unreleased', f'{start_sha}..{head}', None))
    else:
        # Full: all tags + unreleased (descending order - newest first)
        tags = list_tags(tag_filter_re)
        
        if tags:
            # Tags are already in descending order (newest first)
            # Build ranges in reverse chronological order
            prev_tag = None
            for tag, date in tags:
                if prev_tag is None:
                    # Most recent tag (will be used for Unreleased comparison)
                    range_spec = f'{tag}^!'
                    first_tag = tag
                else:
                    # For descending order: current tag..previous tag
                    range_spec = f'{tag}..{prev_tag}'
                
                compare_url = f'https://github.com/{args.repoOwner}/{args.repoName}/compare/{tag}...{prev_tag}' if prev_tag else None
                ranges.append((tag, range_spec, compare_url))
                prev_tag = tag
            
            # Unreleased (at the top, comparing latest tag to HEAD)
            if args.includeUnreleased:
                unreleased_range = f'{first_tag}..{head}'
                unreleased_url = f'https://github.com/{args.repoOwner}/{args.repoName}/compare/{first_tag}...{branch}'
                ranges.insert(0, ('Unreleased', unreleased_range, unreleased_url))
        else:
            # No tags: just show all commits
            ranges.append(('Unreleased', head, None))
    
    if mode == 'up-to-date':
        print(f'INFO: Already up-to-date (HEAD={head[:7]})')
        # Still update timestamp
        save_state(args.state, {
            'lastProcessedSha': head,
            'branch': branch,
            'updatedAt': datetime.utcnow().isoformat() + 'Z',
            'outputFile': args.output
        })
        sys.exit(0)
    
    # Step 3-5: Build changelog
    content = build_changelog(ranges, args.repoOwner, args.repoName, args)
    
    # Step 5: Write
    update_managed_block(args.output, content, args.resetAll)
    
    # Step 6: Persist state
    new_state = {
        'lastProcessedSha': head,
        'branch': branch,
        'updatedAt': datetime.utcnow().isoformat() + 'Z',
        'outputFile': args.output
    }
    save_state(args.state, new_state)
    
    # Step 7: Report
    total_commits = sum(len(group[1]) for section in ranges for group in group_commits([]))  # Simplified
    print(f'DONE: mode={mode}, head={head[:7]}, ranges={len(ranges)}, output={args.output}')

if __name__ == '__main__':
    main()
