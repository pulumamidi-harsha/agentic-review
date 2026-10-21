/**
 * Turn normalized quality-gate findings into Sonar-like peer review comments
 * anchored on the exact file/line in the PR.
 *
 * GitHub review comments render Markdown + <details> collapsibles.
 */
const fs = require('fs');

const FINDING_MARKER = '<!-- agentic-review:finding -->';
const MAX_INLINE = 20;

function readJson(filePath, fallback) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch {
    return fallback;
  }
}

function sevEmoji(sev) {
  return { error: '🔴', warning: '🟡', info: 'ℹ️' }[sev] || '·';
}

function titleFor(finding) {
  const rid = String(finding.rule_id || '').toLowerCase();
  if (rid.includes('eval')) {
    return 'Security hotspot — dynamic code execution (eval)';
  }
  if (rid.includes('regexp') || rid.includes('redos')) {
    return 'Security hotspot — non-literal RegExp (ReDoS risk)';
  }
  if (rid.includes('hardcoded-secret') || rid.includes('secret')) {
    return 'Security hotspot — hardcoded secret';
  }
  if (rid.includes('xss') || rid.includes('innerhtml') || rid.includes('dangerously-set')) {
    return 'Security hotspot — XSS (unsafe HTML)';
  }
  if (rid.includes('command-injection')) {
    return 'Security hotspot — command injection';
  }
  if (rid.includes('insecure-hash')) {
    return 'Security hotspot — weak cryptographic hash';
  }
  if (rid.includes('document-write')) {
    return 'Security hotspot — document.write (XSS risk)';
  }
  const titles = {
    complexity: 'High complexity — please refactor',
    duplication: 'Duplicated code — extract a shared helper',
    coverage: 'Missing or low test coverage',
    secret: 'Hardcoded secret — remove before merge',
    security: 'Security issue — please fix',
    bug: 'Bug risk — please review',
    smell: 'Code smell — please tidy',
    dependency: 'Dependency risk',
    iac: 'Infrastructure issue',
    other: 'Quality finding',
  };
  return titles[finding.category] || titles.other;
}

function whyItMatters(finding) {
  const rid = String(finding.rule_id || '').toLowerCase();
  if (rid.includes('eval')) {
    return (
      'Anyone who controls the string passed to `eval` can run arbitrary code in ' +
      'your process (code injection / RCE). Sonar flags this as a security hotspot for the same reason.'
    );
  }
  if (rid.includes('regexp') || rid.includes('redos')) {
    return (
      'A crafted pattern can hang the event loop (ReDoS). If the pattern comes from ' +
      'users or external data, treat it as untrusted input.'
    );
  }
  if (rid.includes('hardcoded-secret') || (finding.category === 'secret')) {
    return 'Credentials in source leak via git history, forks, and CI logs — treat as already compromised.';
  }
  if (rid.includes('xss') || rid.includes('innerhtml') || rid.includes('dangerously-set') || rid.includes('document-write')) {
    return 'Untrusted HTML in the browser can steal sessions, rewrite the UI, or run attacker scripts (XSS).';
  }
  if (rid.includes('command-injection')) {
    return 'A crafted string can run arbitrary OS commands on the server (RCE).';
  }
  if (rid.includes('insecure-hash')) {
    return 'MD5/SHA-1 are too weak for passwords or security tokens — attackers can crack or collide them.';
  }
  switch (finding.category) {
    case 'complexity':
      return 'Deep branching is hard to test and easy to break when someone changes one path later.';
    case 'duplication':
      return 'Copy-pasted logic means bugs get fixed in one place and left in the other.';
    case 'coverage':
      return 'Without tests on new code, regressions slip through before anyone notices.';
    case 'secret':
      return 'Credentials in source can leak via git history, forks, and CI logs.';
    case 'security':
      return 'This pattern is commonly exploited; fix it before the change lands on main.';
    default:
      return 'Addressing this now keeps the PR small and reviewable.';
  }
}

function whatIsWrong(finding) {
  return (finding.message || 'Quality gate finding').trim();
}

function stepsFromRemediation(rem) {
  if (!rem) return [];
  if (/\(1\)/.test(rem)) {
    const steps = [];
    const re = /\((\d+)\)\s*([^]+?)(?=\s*\(\d+\)\s*|$)/g;
    let m;
    while ((m = re.exec(rem))) {
      const text = m[2].replace(/\s+/g, ' ').replace(/[.\s]+$/, '').trim();
      if (text) steps.push(`${m[1]}. ${text}`);
    }
    if (steps.length) return steps;
  }
  return rem.split('\n').map((l) => l.trim()).filter(Boolean);
}

function codeFence(lang, code) {
  return ['```' + lang, code.trimEnd(), '```'].join('\n');
}

/**
 * Concrete before/after examples (Sonar "How can I fix it?" style).
 */
function fixExamples(finding) {
  const rid = String(finding.rule_id || '').toLowerCase();
  const lang = (finding.path || '').endsWith('.ts') || (finding.path || '').endsWith('.tsx')
    ? 'typescript'
    : 'javascript';

  if (rid.includes('eval')) {
    return {
      intro:
        'Do **not** execute arbitrary strings. Pick a safe alternative for what you actually need:',
      options: [
        {
          title: 'Option A — parse JSON (most common)',
          before: 'export function pilotRunUserScript(userCode: string): unknown {\n  return eval(userCode);\n}',
          after:
            'export function pilotParsePayload(payload: string): unknown {\n' +
            '  return JSON.parse(payload); // throws on invalid JSON — catch at the boundary\n' +
            '}',
        },
        {
          title: 'Option B — whitelist of allowed operations',
          before: 'return eval(userCode);',
          after:
            'type Op = "ping" | "version";\n' +
            'const OPS: Record<Op, () => unknown> = {\n' +
            '  ping: () => "pong",\n' +
            '  version: () => "1.0.0",\n' +
            '};\n' +
            'export function runOp(op: string): unknown {\n' +
            '  const fn = OPS[op as Op];\n' +
            '  if (!fn) throw new Error(`Unsupported op: ${op}`);\n' +
            '  return fn();\n' +
            '}',
        },
      ],
      dont: 'Never pass request bodies, query params, or AI/chat output into `eval` / `new Function`.',
      lang,
    };
  }

  if (rid.includes('regexp') || rid.includes('redos')) {
    return {
      intro: 'Avoid compiling RegExp from untrusted strings.',
      options: [
        {
          title: 'Prefer a literal pattern',
          before:
            'export function pilotMatchDynamic(input: string, pattern: string): boolean {\n' +
            '  const re = new RegExp(pattern);\n' +
            '  return re.test(input);\n' +
            '}',
          after:
            'const EMAIL = /^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$/;\n' +
            'export function pilotMatchEmail(input: string): boolean {\n' +
            '  return EMAIL.test(input);\n' +
            '}',
        },
        {
          title: 'Or allow-list known patterns',
          before: 'const re = new RegExp(pattern);',
          after:
            'const ALLOWED: Record<string, RegExp> = {\n' +
            '  email: /^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$/,\n' +
            '  uuid: /^[0-9a-f-]{36}$/i,\n' +
            '};\n' +
            'export function pilotMatchDynamic(input: string, kind: keyof typeof ALLOWED): boolean {\n' +
            '  return ALLOWED[kind].test(input);\n' +
            '}',
        },
      ],
      dont: 'Do not build RegExp from raw user input without length limits and validation.',
      lang,
    };
  }

  if (rid.includes('hardcoded-secret') || (finding.category === 'secret' && rid.includes('secret'))) {
    return {
      intro: 'Never commit real credentials. Load them at runtime.',
      options: [
        {
          title: 'Use environment variables',
          before: 'export const PILOT_API_KEY = "sk-live-……";',
          after:
            'export const PILOT_API_KEY = process.env.PILOT_API_KEY;\n' +
            'if (!PILOT_API_KEY) throw new Error("PILOT_API_KEY is not configured");',
        },
      ],
      dont: 'Do not leave placeholder “real-looking” keys in the repo — scanners and attackers treat them as live.',
      lang,
    };
  }

  if (rid.includes('xss') || rid.includes('innerhtml') || rid.includes('dangerously-set')) {
    return {
      intro: 'Do not inject unsanitized HTML into the DOM.',
      options: [
        {
          title: 'Prefer textContent',
          before: 'el.innerHTML = userInput;',
          after: 'el.textContent = userInput;',
        },
        {
          title: 'If HTML is required — sanitize first',
          before: '<div dangerouslySetInnerHTML={{ __html: html }} />',
          after:
            "import DOMPurify from 'dompurify';\n" +
            'const safe = DOMPurify.sanitize(html);\n' +
            '<div dangerouslySetInnerHTML={{ __html: safe }} />',
        },
      ],
      dont: 'Never concatenate request/query/AI output into HTML strings.',
      lang,
    };
  }

  if (rid.includes('command-injection')) {
    return {
      intro: 'Do not build a shell command string from untrusted input.',
      options: [
        {
          title: 'Use execFile / spawn with an args array',
          before: "import { exec } from 'child_process';\nexec(`ls ${userPath}`);",
          after:
            "import { execFile } from 'child_process';\n" +
            "execFile('ls', ['-la', userPath], (err, stdout) => { /* … */ });",
        },
      ],
      dont: 'Never pass user input into `exec` / `execSync` as a single shell string.',
      lang,
    };
  }

  if (rid.includes('insecure-hash')) {
    return {
      intro: 'Upgrade the hash algorithm for anything security-sensitive.',
      options: [
        {
          title: 'Integrity / fingerprints',
          before: "crypto.createHash('md5').update(data).digest('hex')",
          after: "crypto.createHash('sha256').update(data).digest('hex')",
        },
        {
          title: 'Passwords',
          before: "createHash('sha1').update(password).digest('hex')",
          after: "await bcrypt.hash(password, 12)  // or argon2 / scrypt",
        },
      ],
      dont: 'Do not use MD5/SHA-1 for passwords or auth tokens.',
      lang,
    };
  }

  if (rid.includes('document-write')) {
    return {
      intro: 'Replace document.write with safe DOM APIs.',
      options: [
        {
          title: 'createElement + textContent',
          before: 'document.write(userHtml);',
          after:
            "const el = document.createElement('div');\n" +
            'el.textContent = userHtml;\n' +
            'document.body.appendChild(el);',
        },
      ],
      dont: 'Never pass untrusted strings to document.write / writeln.',
      lang,
    };
  }

  if (finding.category === 'complexity') {
    const fn = (finding.raw && finding.raw.function) || 'thisFunction';
    const thr = (finding.raw && finding.raw.threshold) || 15;
    return {
      intro: `Split \`${fn}\` so each path is a small helper (target complexity ≤ **${thr}**).`,
      options: [
        {
          title: 'Extract branches into helpers',
          before:
            `export function ${fn}(kind: string, a: number, b: number, flag: boolean): string {\n` +
            '  if (kind === "a") {\n' +
            '    if (a > 10) {\n' +
            '      if (b > 10) {\n' +
            '        // … many nested branches …\n' +
            '      }\n' +
            '    }\n' +
            '  }\n' +
            '  // …\n' +
            '}',
          after:
            'function routeA(a: number, b: number, flag: boolean): string {\n' +
            '  if (a > 10 && b > 10) return flag ? "a-hi-hi-flag" : "a-hi-hi";\n' +
            '  if (a > 10) return flag ? "a-hi-lo-flag" : "a-hi-lo";\n' +
            '  // …\n' +
            '  return "a-lo-lo";\n' +
            '}\n\n' +
            `export function ${fn}(kind: string, a: number, b: number, flag: boolean): string {\n` +
            '  if (kind === "a") return routeA(a, b, flag);\n' +
            '  if (kind === "b") return routeB(a, b, flag);\n' +
            '  if (kind === "c") return routeC(a, b, flag);\n' +
            '  return a === b ? "equal" : a > b ? "gt" : "lt";\n' +
            '}',
        },
      ],
      dont: 'Avoid adding more nested `if` layers to “just make it work”.',
      lang,
    };
  }

  if (finding.category === 'duplication') {
    const other = finding.raw && finding.raw.other_path;
    return {
      intro:
        'Keep one implementation and call it from both places' +
        (other ? ` (also duplicated in \`${other}\`)` : '') +
        '.',
      options: [
        {
          title: 'Extract a shared helper',
          before:
            'export function pilotFormatDupA(name: string, count: number): string {\n' +
            '  const trimmed = (name || "").trim();\n' +
            '  // … identical body …\n' +
            '}\n\n' +
            'export function pilotFormatDupB(name: string, count: number): string {\n' +
            '  const trimmed = (name || "").trim();\n' +
            '  // … same body again …\n' +
            '}',
          after:
            'function formatItem(name: string, count: number): string {\n' +
            '  const trimmed = (name || "").trim();\n' +
            '  const safe = trimmed.length > 0 ? trimmed : "unknown";\n' +
            '  const label = safe.toUpperCase();\n' +
            '  const suffix = count === 1 ? "item" : "items";\n' +
            '  return [`Name: ${label}`, `Count: ${count} ${suffix}`].join(" | ");\n' +
            '}\n\n' +
            'export const pilotFormatDupA = formatItem;\n' +
            'export const pilotFormatDupB = formatItem;',
        },
      ],
      dont: 'Do not keep two copies “for now” — the next bugfix will miss one of them.',
      lang,
    };
  }

  return null;
}

function formatSteps(finding) {
  const rid = String(finding.rule_id || '').toLowerCase();
  // Prefer curated checklists for known hotspots (cleaner than free-text metadata)
  if (rid.includes('eval')) {
    return [
      '1. Delete `eval` / `new Function` from this path',
      '2. Replace with `JSON.parse`, a whitelist map, or a vetted expression library',
      '3. Ensure no user/request/AI input can reach dynamic code execution',
      '4. Add a unit test that proves untrusted strings are rejected',
    ];
  }
  if (rid.includes('regexp') || rid.includes('redos')) {
    return [
      '1. Prefer a literal RegExp (`/pattern/`) when possible',
      '2. If dynamic patterns are required, allow-list known kinds only',
      '3. Bound pattern length and reject nested quantifiers from untrusted input',
    ];
  }
  if (rid.includes('hardcoded-secret') || finding.category === 'secret') {
    return [
      '1. Remove the hardcoded value from source',
      '2. Load it from env / a secret manager at runtime',
      '3. Rotate the credential if it was ever real',
    ];
  }
  if (rid.includes('xss') || rid.includes('innerhtml') || rid.includes('dangerously-set') || rid.includes('document-write')) {
    return [
      '1. Prefer `textContent` / React children for plain text',
      '2. If HTML is required, sanitize with DOMPurify (or equivalent)',
      '3. Block user/request input from reaching raw HTML sinks',
    ];
  }
  if (rid.includes('command-injection')) {
    return [
      '1. Replace `exec(string)` with `execFile` / `spawn` + args array',
      '2. Allow-list the binary and validate every argument',
      '3. Never build a shell string from user/AI input',
    ];
  }
  if (rid.includes('insecure-hash')) {
    return [
      '1. Use SHA-256+ for integrity hashes',
      '2. Use bcrypt / scrypt / argon2 for passwords',
      '3. Re-hash stored values if this was used for auth',
    ];
  }
  if (finding.category === 'complexity') {
    return [
      '1. Extract each major branch into a named helper',
      '2. Prefer early returns or a lookup map over deep nesting',
      '3. Re-run the review and confirm complexity is under the threshold',
    ];
  }
  if (finding.category === 'duplication') {
    return [
      '1. Extract the shared block into one helper',
      '2. Call that helper from every copy',
      '3. Delete the duplicate so there is a single source of truth',
    ];
  }
  const steps = stepsFromRemediation(finding.remediation)
    .map((s) => s.replace(/^[-*]\s+/, '').trim())
    .filter((s) => s && !/^prefer a safe/i.test(s));
  if (!steps.length) {
    return ['1. Fix the issue on this line', '2. Push and re-run the quality gate'];
  }
  return steps.map((s, i) => (s.match(/^\d+\./) ? s : `${i + 1}. ${s}`));
}

function detailsBlock(summary, body, open = false) {
  const content = String(body || '').trim();
  if (!content) return '';
  const openAttr = open ? ' open' : '';
  return `<details${openAttr}>\n<summary>${summary}</summary>\n\n${content}\n\n</details>`;
}

function formatHowToFixDetails(finding) {
  const steps = formatSteps(finding).join('\n');
  const examples = fixExamples(finding);
  const parts = [
    '**Steps**',
    steps,
  ];

  if (examples) {
    parts.push('', examples.intro || '');
    for (const opt of examples.options || []) {
      parts.push(
        '',
        `#### ${opt.title}`,
        '',
        '**Replace this:**',
        codeFence(examples.lang || 'typescript', opt.before),
        '',
        '**With this:**',
        codeFence(examples.lang || 'typescript', opt.after),
      );
    }
    if (examples.dont) {
      parts.push('', `> ⚠️ **Don't:** ${examples.dont}`);
    }
  } else if (finding.raw && finding.raw.snippet) {
    parts.push(
      '',
      '**Flagged code:**',
      codeFence('typescript', String(finding.raw.snippet)),
    );
  }

  // Collapsed by default — expand only when the reviewer wants the fix guide
  return detailsBlock('How can I fix it?', parts.filter(Boolean).join('\n'), false);
}

function formatRiskDetails(finding) {
  const rid = String(finding.rule_id || '').toLowerCase();
  const raw = finding.raw || {};
  const lines = [whyItMatters(finding)];
  if (rid.includes('eval')) {
    lines.push(
      '',
      '- **Category:** Code Injection / RCE',
      '- **Similar to:** SonarQube hotspot S1523 (dynamic code execution)',
      '- **CWE:** CWE-95 (Improper Neutralization of Directives in Dynamically Evaluated Code)',
    );
  }
  if (raw.cwe) {
    const cwe = Array.isArray(raw.cwe) ? raw.cwe.join(', ') : String(raw.cwe);
    if (!lines.some((l) => l.includes('CWE'))) lines.push(`- **CWE:** ${cwe}`);
  }
  if (raw.owasp) {
    const owasp = Array.isArray(raw.owasp) ? raw.owasp.join(', ') : String(raw.owasp);
    lines.push(`- **OWASP:** ${owasp}`);
  }
  return detailsBlock("What's the risk?", lines.join('\n'));
}

function formatPeerBody(finding) {
  const emoji = sevEmoji(finding.severity);
  const title = titleFor(finding);
  const where = finding.path
    ? `\`${finding.path}${finding.start_line ? `:${finding.start_line}` : ''}\``
    : '_repo-wide_';

  return [
    FINDING_MARKER,
    `### ${emoji} ${title}`,
    '',
    `**Where:** ${where}`,
    '',
    `**What's wrong:** ${whatIsWrong(finding)}`,
    '',
    formatRiskDetails(finding),
    '',
    formatHowToFixDetails(finding),
    '',
    `<sub>Engine \`${finding.engine}\` · rule \`${finding.rule_id}\` · severity \`${finding.severity || 'info'}\`</sub>`,
  ].filter(Boolean).join('\n');
}

/**
 * Build GitHub pull-request review comment payloads for findings with a path+line.
 * Coverage / repo-wide findings stay in the summary comment only.
 */
function buildInlineComments(findings, { max = MAX_INLINE } = {}) {
  const list = (Array.isArray(findings) ? findings : [])
    .filter((f) => f && f.in_pr_diff !== false)
    .filter((f) => f.path && f.start_line && Number(f.start_line) > 0)
    .sort((a, b) => {
      const ae = a.severity === 'error' ? 0 : 1;
      const be = b.severity === 'error' ? 0 : 1;
      if (ae !== be) return ae - be;
      return String(a.path).localeCompare(String(b.path))
        || (Number(a.start_line) - Number(b.start_line));
    })
    .slice(0, max);

  return list.map((f) => {
    const line = Number(f.start_line);
    const end = f.end_line && Number(f.end_line) > line ? Number(f.end_line) : null;
    const comment = {
      path: String(f.path).replace(/^\.\//, ''),
      side: 'RIGHT',
      line,
      body: formatPeerBody(f),
    };
    // Multi-line highlight when the engine gave a span (GitHub API)
    if (end && end > line) {
      comment.start_line = line;
      comment.start_side = 'RIGHT';
      comment.line = end;
    }
    return comment;
  });
}

function loadFindingsBundle(agenticTmp) {
  const bundle = readJson(`${agenticTmp}/findings.json`, null);
  if (bundle && Array.isArray(bundle.findings)) return bundle.findings;
  const merged = [];
  for (const name of [
    'semgrep-findings.json',
    'jscpd-findings.json',
    'lizard-findings.json',
    'coverage-findings.json',
  ]) {
    const arr = readJson(`${agenticTmp}/${name}`, []);
    if (Array.isArray(arr)) merged.push(...arr);
  }
  return merged;
}

module.exports = {
  FINDING_MARKER,
  loadFindingsBundle,
  buildInlineComments,
  formatPeerBody,
};
