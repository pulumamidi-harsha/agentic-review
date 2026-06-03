const fs = require('fs');

const AGENTIC_TMP = process.env.AGENTIC_TMP || '/tmp/agentic-review';

function read(path, fallback = '') {
  try { return fs.readFileSync(path, 'utf8'); } catch { return fallback; }
}

function details(summary, content, open = false) {
  if (!content || !String(content).trim()) return '';
  const tag = open ? '<details open>' : '<details>';
  return `${tag}<summary>${summary}</summary>\n\n${String(content).trim()}\n\n</details>\n`;
}

/** Normalize LLM fields that may be string, array, or object. */
function toBulletLines(value) {
  if (value == null || value === '') return [];
  if (Array.isArray(value)) {
    return value.flatMap(v => toBulletLines(v));
  }
  if (typeof value === 'object') {
    return Object.entries(value).map(([k, v]) => `- ${k}: ${v}`);
  }
  return String(value).split('\n').map(l => l.trim()).filter(Boolean);
}

function shortSummary(text, maxLen = 320) {
  const t = (Array.isArray(text) ? text.join(' ') : String(text || '')).trim();
  if (t.length <= maxLen) return t;
  const cut = t.slice(0, maxLen);
  const last = cut.lastIndexOf('. ');
  return (last > 120 ? cut.slice(0, last + 1) : cut) + '… _(expand sections below)_';
}

let review = read(`${AGENTIC_TMP}/ai-review.txt`, '{}');
let checks = read(`${AGENTIC_TMP}/check-results.txt`, 'No results');
let commands = {};
try { commands = JSON.parse(read(`${AGENTIC_TMP}/ai-commands.json`, '{}')); } catch {}
const dockerResults = read(`${AGENTIC_TMP}/docker-results.txt`).trim();
const securityResults = read(`${AGENTIC_TMP}/security-results.txt`).trim();
const auditResults = read(`${AGENTIC_TMP}/audit-results.txt`).trim();
const sonarResults = read(`${AGENTIC_TMP}/sonar-results.txt`).trim();
const customPayload = read(`${AGENTIC_TMP}/validated-payload.txt`).trim();
const checkCoverageMd = read(`${AGENTIC_TMP}/check-coverage.md`).trim();
const pass1SummaryMd = read(`${AGENTIC_TMP}/pass1-summary.md`).trim();
const instructionSource = read(`${AGENTIC_TMP}/instruction-source.txt`, 'none').trim();

const passed = process.env.CHECKS_PASSED ?? '0';
const failed = process.env.CHECKS_FAILED ?? '0';
const checksExit = process.env.CHECKS_EXIT ?? '0';
const setupFailed = process.env.SETUP_FAILED === 'true';
const dockerFound = process.env.DOCKER_FOUND === 'true';
const securityExit = process.env.SECURITY_EXIT || '0';
const prSize = process.env.PR_SIZE || 'normal';
const diffLines = process.env.DIFF_LINES || '0';
const changedFiles = process.env.CHANGED_FILES || '0';
const reviewType = process.env.REVIEW_TYPE || 'full';

const startTime = parseInt(process.env.TIMER_START || '0', 10);
const duration = startTime ? Math.round(Date.now() / 1000) - startTime : 0;
const durationStr = duration > 60 ? `${Math.floor(duration / 60)}m ${duration % 60}s` : `${duration}s`;

let reviewData = {};
try {
  const cleaned = review.replace(/^```json\n?/, '').replace(/\n?```$/, '');
  reviewData = JSON.parse(cleaned);
} catch {
  reviewData = { summary: review.substring(0, 500), verdict: 'comment', confidence: 0, issues: [], positives: [], suggestions: [] };
}

const stackInfo = commands.stack
  ? `${commands.stack.language || '?'} / ${commands.stack.framework || '?'} / ${commands.stack.package_manager || '?'}`
  : 'Unknown';

const payloadAnalysis = commands.payload_analysis || null;

const cmdList = (commands.check_commands || [])
  .map((c, i) => `${i + 1}. \`${c.cmd}\`\n   - ${c.purpose} [${c.confidence}]`)
  .join('\n');

const verdictMap = { approve: ['\u2705', 'APPROVED'], needs_work: ['\u26a0\ufe0f', 'NEEDS WORK'], reject: ['\ud83d\udd34', 'CHANGES REQUIRED'] };
const [verdictEmoji, verdictLabel] = verdictMap[reviewData.verdict] || ['\u2139\ufe0f', 'REVIEW'];
const statusEmoji = checksExit === '0' ? '\u2705' : (setupFailed ? '\u26a0\ufe0f' : '\u274c');

const formatIssue = (i) => {
  const sev = { critical: '\ud83d\udea8', high: '\ud83d\udd34', medium: '\ud83d\udfe1', low: '\ud83d\udd35', info: '\u2139\ufe0f' }[i.severity] || '-';
  const loc = i.file ? `\`${i.file}${i.line ? ':' + i.line : ''}\`` : '';
  return `${sev} **${i.title}** ${loc}\n   ${i.description}${i.suggestion ? '\n   \ud83d\udca1 ' + i.suggestion : ''}`;
};

const prIssues = (reviewData.issues || []).filter(i => i.is_pr_change !== false);
const otherIssues = (reviewData.issues || []).filter(i => i.is_pr_change === false);
const issuesInPr = prIssues.map(formatIssue).join('\n\n');
const issuesOther = otherIssues.map(formatIssue).join('\n\n');

const verdictReasons = reviewData.verdict_reasons || [];
const prReasons = verdictReasons.filter(r => r.scope === 'pr_change');
const outsideReasons = verdictReasons.filter(r => r.scope === 'check_failure_outside_diff' || r.scope === 'pre_existing');
const prChangedFiles = read(`${AGENTIC_TMP}/pr-changed-files.txt`).trim().split('\n').filter(Boolean);

let verdictWhySection = '';
if (reviewData.verdict_rationale || prChangedFiles.length || prReasons.length) {
  const lines = [];
  if (prChangedFiles.length) {
    lines.push(`**Files you changed:** ${prChangedFiles.map(f => `\`${f}\``).join(', ')}`);
  }
  toBulletLines(reviewData.verdict_rationale).forEach(l => {
    lines.push(l.startsWith('-') ? l : `- ${l}`);
  });
  if (prReasons.length) {
    lines.push('', '**Blocking reasons (in your diff):**');
    prReasons.forEach(r => lines.push(`- \`${r.file || 'PR'}\`: ${r.reason}`));
  }
  if (outsideReasons.length) {
    lines.push('', '**Not counted against this PR:**');
    outsideReasons.forEach(r => lines.push(`- ${r.reason}`));
  }
  verdictWhySection = `### Why **${verdictLabel}**\n\n${lines.join('\n')}\n`;
}

const ownerInstructionsBlock = customPayload ? [
  customPayload.split('\n').filter(l => l.trim()).map(l => `> ${l.trim()}`).join('\n'),
  '',
  '**Priority:** Owner instructions override auto-detection when they conflict.',
  `- Source: \`${instructionSource}\``,
  `- Accepted: ${payloadAnalysis?.accepted_count ?? 'all'}`,
  payloadAnalysis?.overrides?.length
    ? '\n**Decisions:**\n' + payloadAnalysis.overrides.map(o => `- ${o}`).join('\n')
    : '',
].join('\n') : '';

const pass1Block = [
  '| Item | Value |',
  '|------|-------|',
  `| Instruction source | \`${instructionSource}\` |`,
  `| Setup / check commands | ${(commands.setup_commands || []).length} / ${(commands.check_commands || []).length} |`,
  `| Dependency audit | ${commands.dependency_audit?.cmd ? 'yes' : 'skipped'} |`,
  '',
  '**Setup:**',
  (commands.setup_commands || []).length
    ? commands.setup_commands.map((c, i) => `${i + 1}. \`${c.cmd}\` — ${c.purpose}`).join('\n')
    : '_None_',
  '',
  '**Checks:**',
  cmdList || '_None_',
].join('\n');

const repoHealth = reviewData.repo_health || {};
const healthEmoji = { healthy: '\u2705', needs_attention: '\u26a0\ufe0f', critical: '\ud83d\udea8' }[repoHealth.status] || '\u2139\ufe0f';
const repoHealthBlock = repoHealth.summary ? [
  `**Status:** ${healthEmoji} ${(repoHealth.status || 'unknown').replace(/_/g, ' ')}`,
  '',
  repoHealth.summary,
  '',
  (repoHealth.issues || []).length
    ? '**Pre-existing:**\n' + repoHealth.issues.map(i =>
      typeof i === 'string' ? `- ${i}` : `- ${i.title || i.description || ''}`
    ).filter(Boolean).join('\n')
    : '',
  (repoHealth.recommendations || []).length
    ? '\n**Recommendations:**\n' + repoHealth.recommendations.map(r => `- ${r}`).join('\n')
    : '',
].filter(Boolean).join('\n') : '';

const positives = (reviewData.positives || []).map(p => `- ${p}`).join('\n');
const suggestions = (reviewData.suggestions || []).map(s => `- ${s}`).join('\n');

const commandsDetail = [
  '**Setup:**',
  (commands.setup_commands || []).length
    ? commands.setup_commands.map((c, i) => `${i + 1}. \`${c.cmd}\`\n   - ${c.purpose}`).join('\n\n')
    : '_None_',
  '',
  '**Checks:**',
  cmdList || '_None_',
  '',
  commands.dependency_audit?.cmd
    ? `**Audit:** \`${commands.dependency_audit.cmd}\``
    : '**Audit:** _skipped_',
].join('\n');

const sizeWarning = prSize === 'very_large'
  ? `> \u26a0\ufe0f Large PR (${diffLines} lines, ${changedFiles} files).\n`
  : prSize === 'large'
  ? `> \ud83d\udcdd ${diffLines} lines, ${changedFiles} files.\n`
  : '';

const issueCountPr = prIssues.length;
const issueCountOther = otherIssues.length;

const body = [
  `## \ud83e\udd16 AI Code Review \u2014 ${verdictEmoji} ${verdictLabel}`,
  '',
  `> ${shortSummary(reviewData.summary)}`,
  verdictWhySection,
  sizeWarning,
  `| Stack | Checks | Security | Mode | Time |`,
  `|-------|--------|----------|------|------|`,
  `| ${stackInfo} | ${statusEmoji} ${passed} ok, ${failed} fail | ${securityExit === '0' ? '\u2705' : '\u26a0\ufe0f'} | ${reviewType} | ${durationStr} |`,
  '',
  issueCountPr > 0
    ? `### Issues in your changed files (${issueCountPr})\n\n${issuesInPr}\n`
    : `### Issues in your changed files\n\nNone identified in this PR\u2019s diff.\n`,
  '',
  customPayload ? details('\ud83d\udccb Owner instructions', ownerInstructionsBlock) : '',
  details('\u2699\ufe0f Pass 1 — commands chosen', pass1Block),
  details('\ud83d\udcca Minimum CI check coverage', checkCoverageMd),
  details('\ud83c\udfe5 Repository health (pre-existing)', repoHealthBlock),
  details(`\ud83d\udd0d Other findings outside your diff (${issueCountOther})`, issuesOther),
  details('\ud83e\uddea CI analysis', reviewData.check_results_analysis),
  details('\ud83d\udd12 Security analysis', reviewData.security_analysis),
  details('\u2705 What\u2019s good', positives),
  details('\ud83d\udca1 Suggestions', suggestions),
  details('\ud83d\udccb Full command list', commandsDetail),
  pass1SummaryMd ? details('\ud83d\udd0d Pass 1 JSON summary', pass1SummaryMd) : '',
  details('\ud83d\udcca Full check output', checks),
  dockerFound ? details('\ud83d\udc33 Docker & Trivy', dockerResults) : '',
  securityResults ? details('\ud83d\udee1\ufe0f Security & hygiene scans', securityResults) : '',
  auditResults ? details('\ud83d\udce6 Dependency audit', auditResults) : '',
  sonarResults ? details('\ud83d\udcca SonarQube', sonarResults) : '',
  '',
  '---',
  `<sub>\ud83e\udd16 <a href="https://github.com/pulumamidi-harsha/agentic-review">agentic-review</a> \u00b7 ${changedFiles} files \u00b7 ${diffLines} diff lines \u00b7 ${durationStr}</sub>`,
].filter(Boolean).join('\n');

module.exports = { body, reviewData, durationStr };
