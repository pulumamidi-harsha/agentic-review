const fs = require('fs');

const AGENTIC_TMP = process.env.AGENTIC_TMP || '/tmp/agentic-review';

function read(path, fallback = '') {
  try { return fs.readFileSync(path, 'utf8'); } catch { return fallback; }
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
let checkCoverage = {};
try { checkCoverage = JSON.parse(read(`${AGENTIC_TMP}/check-coverage.json`, '{}')); } catch {}

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

const allStacks = commands.stacks || [];
const multiStackInfo = allStacks.length > 1
  ? '\n\n**Detected Stacks:**\n' + allStacks.map(s => `- ${s.language}${s.framework ? ' / ' + s.framework : ''} (\`${s.directory || 'root'}\`)`).join('\n') + '\n'
  : '';

const payloadAnalysis = commands.payload_analysis || null;
let customInstructionsSection = '';
if (customPayload) {
  const payloadLines = customPayload.split('\n').filter(l => l.trim()).map(l => `> ${l.trim()}`).join('\n');
  const overrides = payloadAnalysis?.overrides?.length > 0
    ? payloadAnalysis.overrides.map(o => `- ${o}`).join('\n')
    : '- AI detection aligned with owner instructions (no conflicts)';
  customInstructionsSection = [
    '### 📋 Repository Owner Instructions',
    '',
    payloadLines,
    '',
    '**AI Priority Analysis:**',
    `- Instructions accepted: ${payloadAnalysis?.accepted_count || 'all'}`,
    `- Priority: Owner instructions > AI auto-detection`,
    overrides ? `\n**Decisions:**\n${overrides}` : '',
    ''
  ].join('\n');
}

const cmdList = (commands.check_commands || [])
  .map((c, i) => `${i + 1}. \`${c.cmd}\`\n   - **Purpose:** ${c.purpose}\n   - **Confidence:** ${c.confidence}\n`)
  .join('\n');

const verdictMap = { approve: ['\u2705', 'APPROVED'], needs_work: ['\u26a0\ufe0f', 'NEEDS WORK'], reject: ['\ud83d\udd34', 'CHANGES REQUIRED'] };
const [verdictEmoji, verdictLabel] = verdictMap[reviewData.verdict] || ['\u2139\ufe0f', 'REVIEW'];
const statusEmoji = checksExit === '0' ? '\u2705' : (setupFailed ? '\u26a0\ufe0f' : '\u274c');

const issuesList = (reviewData.issues || []).map(i => {
  const sev = { critical: '\ud83d\udea8', high: '\ud83d\udd34', medium: '\ud83d\udfe1', low: '\ud83d\udd35', info: '\u2139\ufe0f' }[i.severity] || '-';
  const loc = i.file ? `\`${i.file}${i.line ? ':' + i.line : ''}\`` : '';
  return `${sev} **${i.title}** ${loc}\n   ${i.description}${i.suggestion ? '\n   \ud83d\udca1 ' + i.suggestion : ''}`;
}).join('\n\n');

const positives = (reviewData.positives || []).map(p => `- ${p}`).join('\n');
const suggestions = (reviewData.suggestions || []).map(s => `- ${s}`).join('\n');

const repoHealth = reviewData.repo_health || {};
const healthEmoji = { healthy: '\u2705', needs_attention: '\u26a0\ufe0f', critical: '\ud83d\udea8' }[repoHealth.status] || '\u2139\ufe0f';
const repoHealthSection = repoHealth.summary ? [
  `### \ud83c\udfe5 Repository Health \u2014 ${healthEmoji} ${(repoHealth.status || 'unknown').replace('_', ' ').toUpperCase()}`,
  '',
  `> ${repoHealth.summary}`,
  '',
  (repoHealth.issues || []).length > 0 ? '**Pre-existing issues (not introduced by this PR):**\n' + repoHealth.issues.map(i => `- ${i}`).join('\n') + '\n' : '',
  (repoHealth.recommendations || []).length > 0 ? '**Recommendations:**\n' + repoHealth.recommendations.map(r => `- ${r}`).join('\n') + '\n' : '',
].filter(Boolean).join('\n') : '';

const sizeWarning = prSize === 'very_large'
  ? `\n> \u26a0\ufe0f **Large PR** (${diffLines} lines across ${changedFiles} files).\n`
  : prSize === 'large'
  ? `\n> \ud83d\udcdd PR has ${diffLines} lines across ${changedFiles} files.\n`
  : '';

const body = [
  `## \ud83e\udd16 AI Code Review \u2014 ${verdictEmoji} ${verdictLabel}`,
  '',
  `> ${reviewData.summary || 'Review complete.'}`,
  sizeWarning,
  `| Stack | Checks | Security | Mode | Duration |`,
  `|-------|--------|----------|------|----------|`,
  `| ${stackInfo} | ${statusEmoji} ${passed} passed, ${failed} failed | ${securityExit === '0' ? '\u2705' : '\u26a0\ufe0f'} | ${reviewType} | ${durationStr} |`,
  multiStackInfo,
  '',
  customInstructionsSection,
  '',
  checkCoverageMd ? (checkCoverage.gap_count > 0
    ? `### \u26a0\ufe0f Minimum CI checks \u2014 gaps in repository setup\n\n${checkCoverageMd}\n`
    : `### \u2705 Minimum CI check coverage\n\n${checkCoverageMd}\n`) : '',
  '',
  repoHealthSection,
  '',
  reviewData.check_results_analysis ? `### CI Analysis\n${reviewData.check_results_analysis}\n` : '',
  reviewData.security_analysis ? `### Security Analysis\n${reviewData.security_analysis}\n` : '',
  issuesList ? `### Issues Found\n\n${issuesList}\n` : '',
  positives ? `### \u2705 What\u2019s Good\n\n${positives}\n` : '',
  suggestions ? `### \ud83d\udca1 Suggestions\n\n${suggestions}\n` : '',
  '',
  '<details><summary>\ud83d\udccb Commands AI decided to run</summary>',
  '',
  cmdList || '_None generated_',
  '',
  '</details>',
  '',
  '<details><summary>\ud83d\udcca Full Check Output</summary>',
  '',
  checks,
  '',
  '</details>',
  '',
  dockerFound ? '<details><summary>\ud83d\udc33 Docker Build & Trivy Scan</summary>\n\n' + dockerResults + '\n\n</details>\n' : '',
  securityResults ? '<details><summary>\ud83d\udd12 Security & File Hygiene Scans</summary>\n\n' + securityResults + '\n\n</details>\n' : '',
  auditResults ? '<details><summary>\ud83d\udce6 Dependency Vulnerability Audit</summary>\n\n' + auditResults + '\n\n</details>\n' : '',
  sonarResults ? '<details><summary>\ud83d\udcca SonarQube Analysis</summary>\n\n' + sonarResults + '\n\n</details>\n' : '',
  '',
  '---',
  `<sub>\ud83e\udd16 Powered by <a href="https://github.com/pulumamidi-harsha/agentic-review">agentic-review</a> | ${changedFiles} files, ${diffLines} lines | ${durationStr}</sub>`,
].filter(Boolean).join('\n');

module.exports = { body, reviewData, durationStr };
