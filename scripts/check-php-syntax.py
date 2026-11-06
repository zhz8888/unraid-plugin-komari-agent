#!/usr/bin/env python3
"""Heuristic syntax check for the plugin's PHP files.

The Unraid host runs the WebGUI page, and a syntax error there breaks the
Settings page. This script is not a PHP parser; it tokenises the file well
enough to catch the mistakes that actually happen in practice:

  * unbalanced braces, parentheses or brackets
  * an unterminated string or heredoc
  * a PHP block that is never closed
  * a stray closing tag
  * a call to a function the plugin defines but never declares

It is a supplement to `php -l`, not a replacement for it: run `php -l` on the
files when a PHP binary is available.

Usage:
    python3 scripts/check-php-syntax.py src/
"""

import os
import re
import sys

OPEN = {'{': '}', '(': ')', '[': ']'}
CLOSE = {'}': '{', ')': '(', ']': '['}


def check(path):
    """Return a list of problems found in path."""
    problems = []
    with open(path, encoding='utf-8') as handle:
        text = handle.read()

    stack = []
    line = 1
    index = 0
    length = len(text)
    in_php = False
    saw_close_tag = False
    in_string = None
    in_line_comment = False
    in_block_comment = False

    while index < length:
        char = text[index]
        nxt = text[index + 1] if index + 1 < length else ''

        if char == '\n':
            line += 1
            in_line_comment = False
            index += 1
            continue

        if in_line_comment:
            index += 1
            continue

        if in_block_comment:
            if char == '*' and nxt == '/':
                in_block_comment = False
                index += 2
                continue
            index += 1
            continue

        if in_string is not None:
            if char == '\\':
                index += 2
                continue
            if char == in_string:
                in_string = None
            index += 1
            continue

        if not in_php:
            # Look for an opening tag. The tag itself has to be consumed by
            # its own length: "<?php" does not contain a ">", so searching for
            # the next ">" would skip real code.
            for tag in ('<?php', '<?=', '<?'):
                if text.startswith(tag, index):
                    in_php = True
                    saw_close_tag = False
                    index += len(tag)
                    break
            else:
                index += 1
            continue

        # --- inside PHP --------------------------------------------------
        if text.startswith('?>', index):
            in_php = False
            saw_close_tag = True
            index += 2
            continue

        if char in ('"', "'"):
            in_string = char
            index += 1
            continue

        if text.startswith('//', index) or (char == '#' and not text.startswith('#[', index)):
            in_line_comment = True
            index += 2 if text.startswith('//', index) else 1
            continue

        if text.startswith('/*', index):
            in_block_comment = True
            index += 2
            continue

        # Heredoc and nowdoc.
        if text.startswith('<<<', index):
            match = re.match(r'<<<[ \t]*(["\']?)([A-Za-z_][A-Za-z0-9_]*)\1[ \t]*\r?\n', text[index:])
            if match:
                marker = match.group(2)
                body_start = index + match.end()
                end = re.search(r'^[ \t]*' + re.escape(marker) + r'\b', text[body_start:], re.M)
                if end is None:
                    problems.append(f'{path}:{line}: unterminated heredoc/nowdoc <<<{marker}')
                    return problems
                consumed = text[body_start:body_start + end.end()]
                line += consumed.count('\n')
                index = body_start + end.end()
                continue

        if char in OPEN:
            stack.append((char, line))
            index += 1
            continue

        if char in CLOSE:
            if not stack:
                problems.append(f'{path}:{line}: unmatched {char!r}')
            else:
                opener, opened_at = stack.pop()
                if OPEN[opener] != char:
                    problems.append(
                        f'{path}:{line}: {char!r} closes {opener!r} opened at line {opened_at}')
            index += 1
            continue

        index += 1

    if in_string is not None:
        problems.append(f'{path}:{line}: unterminated string literal ({in_string})')
    if in_block_comment:
        problems.append(f'{path}:{line}: unterminated block comment')
    # A file that is PHP from the first line to the last is the recommended
    # style and must NOT carry a closing tag: PHP's own manual says a trailing
    # "?>" risks emitting stray whitespace into the response. Only a file that
    # mixes HTML and PHP has to close every PHP block it opens.
    if in_php and not _is_pure_php(text):
        problems.append(f'{path}:{line}: PHP block is never closed with "?>"')
    for opener, opened_at in stack:
        problems.append(f'{path}:{opened_at}: {opener!r} is never closed')

    return problems


def _is_pure_php(text):
    """True when the file is PHP from its first non-blank character on."""
    stripped = text.lstrip('\ufeff \t\r\n')
    return stripped.startswith('<?php')


def iter_php_files(root):
    if os.path.isfile(root):
        yield root
        return
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            if name.endswith('.php'):
                yield os.path.join(dirpath, name)


def iter_page_files(root):
    """Return the Dynamix .page files, which embed PHP after a --- separator."""
    if os.path.isfile(root):
        if root.endswith('.page'):
            yield root
        return
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            if name.endswith('.page'):
                yield os.path.join(dirpath, name)


def check_page(path):
    """Validate the header block and the embedded PHP of a Dynamix .page file."""
    problems = []
    with open(path, encoding='utf-8') as handle:
        text = handle.read()

    if '\r' in text:
        problems.append(f'{path}: contains CRLF line endings; Dynamix expects LF')

    separator = text.find('\n---\n')
    if separator == -1:
        if text.startswith('---\n'):
            separator = 0
        else:
            problems.append(f'{path}: no "---" separator between the header and the body')
            return problems

    header = text[:separator] if separator else ''
    for line_number, line in enumerate(header.splitlines(), start=1):
        stripped = line.strip()
        if not stripped:
            continue
        if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*="[^"]*"', stripped):
            problems.append(
                f'{path}:{line_number}: header line is not key="value": {stripped!r}')

    body_start = separator + len('\n---\n') if separator else len('---\n')
    body = text[body_start:]
    if '<?php' in body:
        problems.extend(check_body(path, body, body_start))
    return problems


def check_body(path, body, offset):
    """Run the brace/string scanner over an in-memory body."""
    import tempfile
    with tempfile.NamedTemporaryFile('w', suffix='.php', delete=False,
                                     encoding='utf-8', newline='\n') as handle:
        handle.write(body)
        temp_path = handle.name
    try:
        found = check(temp_path)
    finally:
        os.unlink(temp_path)
    return [problem.replace(temp_path, path, 1) for problem in found]


def check_defined_functions(root):
    """Cross-check komari_ helper calls against the helpers that are declared.

    A typo in a helper name is a fatal error at request time and the heuristic
    scanner above cannot see it, because the call is syntactically valid.

    The prefix has to match what the code base actually uses. This project
    names its helpers komari_*; matching a different prefix would leave the
    check permanently green while never looking at a single call.
    """
    problems = []
    if not os.path.isdir(root):
        return problems

    defined = set()
    called = {}
    pattern_def = re.compile(r'^\s*function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(', re.M)
    pattern_call = re.compile(r'\b(komari_[a-z0-9_]+)\s*\(')

    files = list(iter_php_files(root)) + list(iter_page_files(root))
    for path in files:
        try:
            text = open(path, encoding='utf-8').read()
        except OSError:
            continue
        defined.update(pattern_def.findall(text))
        for name in pattern_call.findall(text):
            called.setdefault(name, set()).add(path)

    for name, paths in sorted(called.items()):
        if name not in defined:
            for path in sorted(paths):
                problems.append(f'{path}: calls undefined helper {name}()')

    return problems


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else 'src'
    problems = []

    php_files = list(iter_php_files(root))
    for path in php_files:
        problems.extend(check(path))

    page_files = list(iter_page_files(root))
    for path in page_files:
        problems.extend(check_page(path))

    problems.extend(check_defined_functions(root))

    if not php_files and not page_files:
        print(f'no PHP or .page files found under {root}', file=sys.stderr)
        return 1

    for problem in problems:
        print(problem, file=sys.stderr)

    if problems:
        print(f'\n{len(problems)} problem(s) found', file=sys.stderr)
        return 1

    print(f'checked {len(php_files)} PHP file(s) and {len(page_files)} .page file(s): OK')
    return 0


if __name__ == '__main__':
    sys.exit(main())
