/**
 * Turn normalized quality-gate findings into Sonar-like peer review comments
 * anchored on the exact file/line in the PR.
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
  const cat = finding.category || 'other';
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
  return titles[cat] || titles.other;
}

function whyItMatters(finding) {
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

function howToFix(finding) {
  const rem = (finding.remediation || '').trim();
  if (rem) {
    // Turn "(1) … (2) … (3) …" into a numbered checklist
    if (/\(1\)/.test(rem)) {
      const steps = [];
      const re = /\((\d+)\)\s*([^]+?)(?=\s*\(\d+\)\s*|$)/g;
      let m;
      while ((m = re.exec(rem))) {
        const text = m[2].replace(/\s+/g, ' ').replace(/[.\s]+$/, '').trim();
        if (text) steps.push(`${m[1]}. ${text}`);
      }
      if (steps.length) return steps.join('\n');
    }
    return rem;
  }
  switch (finding.category) {
    case 'complexity':
      return [
        '1. Split each major branch into a small named helper',
        '2. Prefer early returns or a lookup map over deep nesting',
        '3. Re-run the review and confirm complexity is under the threshold',
      ].join('\n');
    case 'duplication':
      return [
        '1. Extract the shared block into one helper',
        '2. Call that helper from every copy',
        '3. Delete the duplicate so there is a single source of truth',
      ].join('\n');
    case 'coverage':
      return [
        '1. Add unit tests for the new/changed branches',
        '2. Ensure CI publishes an lcov/cobertura/istanbul report',
        '3. Re-run so the coverage gate can evaluate the PR',
      ].join('\n');
    default:
      return 'Please fix this finding and push an update so the gate can re-check.';
  }
}

function formatPeerBody(finding) {
  const emoji = sevEmoji(finding.severity);
  const title = titleFor(finding);
  const where = finding.path
    ? `\`${finding.path}${finding.start_line ? `:${finding.start_line}` : ''}\``
    : '_repo-wide_';
  const how = howToFix(finding)
    .split('\n')
    .map((l) => (l.match(/^\d+\./) ? l : `- ${l}`))
    .join('\n');

  return [
    FINDING_MARKER,
    `### ${emoji} ${title}`,
    '',
    `**Where:** ${where}`,
    '',
    `**What's wrong:** ${whatIsWrong(finding)}`,
    '',
    `**Why it matters:** ${whyItMatters(finding)}`,
    '',
    '**How to fix:**',
    how,
    '',
    `<sub>Engine \`${finding.engine}\` · rule \`${finding.rule_id}\` · severity \`${finding.severity || 'info'}\`</sub>`,
  ].join('\n');
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
  // Fall back to per-engine stubs
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
