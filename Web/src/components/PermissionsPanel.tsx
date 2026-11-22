import { useEffect, useState } from 'react'
import { api, errorMessage } from '../api/client'
import type { PermissionMode, PermissionPolicy, PermissionRule, PermissionsView } from '../api/types'
import { useI18n } from '../i18n'
import { Icon } from './coordinator/Icon'
import { Switch } from './coordinator/WorkspacePanels'
import { ErrorBanner, Spinner } from './ui'

/** Plain names for the write tools a standing permission can cover. */
export const PERMISSION_TOOL_LABELS: Record<string, string> = {
  gmail_draft: 'Create Gmail drafts',
  gmail_send: 'Send email from Gmail',
  github_write_file: 'Commit files on GitHub',
  github_comment: 'Comment on GitHub issues and pull requests',
  googleads_set_status: 'Pause or enable Google Ads campaigns and ads',
  googleads_set_budget: 'Change Google Ads budgets',
  googleads_mutate: 'Other Google Ads changes',
  cloudflare_dns_create: 'Add DNS records',
  cloudflare_dns_update: 'Change DNS records',
  cloudflare_dns_delete: 'Delete DNS records',
  cloudflare_purge_cache: 'Purge the Cloudflare cache',
}

const APPROVAL_MINUTES = [15, 60, 240, 720, 1440]

function minutesLabel(minutes: number, t: (key: string, values?: Record<string, string | number>) => string): string {
  if (minutes < 60) return t('{count} minutes', { count: minutes })
  if (minutes === 60) return t('1 hour')
  return t('{count} hours', { count: minutes / 60 })
}

function numberOrUndefined(value: string): number | undefined {
  const parsed = Number(value)
  return value.trim() && Number.isFinite(parsed) && parsed > 0 ? parsed : undefined
}

/** Settings for what Ada may do on her own: a rule per write tool, limits, and a pause switch. */
export function PermissionsPanel() {
  const { t } = useI18n()
  const [view, setView] = useState<PermissionsView | null>(null)
  const [policy, setPolicy] = useState<PermissionPolicy | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [saved, setSaved] = useState(false)

  useEffect(() => {
    void api<PermissionsView>('access/permissions').then((loaded) => { setView(loaded); setPolicy(loaded.policy) }).catch((err) => setError(errorMessage(err)))
  }, [])

  if (!view || !policy) return error ? <ErrorBanner message={error} /> : <Spinner />
  const editable = view.canEdit
  const dirty = JSON.stringify(policy) !== JSON.stringify(view.policy)

  const update = (next: PermissionPolicy) => { setPolicy(next); setSaved(false) }
  const setRule = (tool: string, rule: PermissionRule | null) => {
    const rules = { ...policy.rules }
    if (rule && rule.mode !== 'ask') rules[tool] = rule
    else delete rules[tool]
    update({ ...policy, rules })
  }
  const save = async () => {
    setSaving(true)
    setError(null)
    try {
      const next = await api<PermissionsView>('access/permissions', { method: 'PUT', body: policy })
      setView(next)
      setPolicy(next.policy)
      setSaved(true)
    } catch (err) { setError(errorMessage(err)) } finally { setSaving(false) }
  }

  return <section>
    <div className="co-setting-card">
      <div className="co-setting-row">
        <div><b>{t('Pause automatic actions')}</b><p>{t('While paused, everything Ada would do on her own asks you first. “Never” rules still refuse.')}</p></div>
        <Switch checked={policy.paused} label={t('Pause automatic actions')} disabled={!editable} onChange={() => update({ ...policy, paused: !policy.paused })} />
      </div>
      <div className="co-setting-row">
        <div><b>{t('Approval cards stay open for')}</b><p>{t('Longer times let scheduled runs wait for you instead of expiring.')}</p></div>
        <select value={policy.approvalMinutes} disabled={!editable} aria-label={t('Approval cards stay open for')} onChange={(event) => update({ ...policy, approvalMinutes: Number(event.target.value) })}>
          {APPROVAL_MINUTES.map((minutes) => <option key={minutes} value={minutes}>{minutesLabel(minutes, t)}</option>)}
        </select>
      </div>
    </div>

    <div className="settings-cards permission-rules">
      {view.tools.map((tool) => {
        const rule = policy.rules[tool] ?? { mode: 'ask' as PermissionMode }
        const used = view.usageToday[tool] ?? 0
        const setField = (patch: Partial<PermissionRule>) => setRule(tool, { ...rule, ...patch })
        return <div key={tool} className="co-setting-card permission-rule">
          <div className="co-setting-row">
            <div><b>{t(PERMISSION_TOOL_LABELS[tool] ?? tool)}</b><p><code>{tool}</code>{used ? ` · ${t('{count} automatic today', { count: used })}` : ''}</p></div>
            <select value={rule.mode} disabled={!editable} aria-label={t(PERMISSION_TOOL_LABELS[tool] ?? tool)} onChange={(event) => setField({ mode: event.target.value as PermissionMode })}>
              <option value="ask">{t('Ask me each time')}</option>
              <option value="allow">{t('Allow without asking')}</option>
              <option value="never">{t('Never')}</option>
            </select>
          </div>
          {rule.mode === 'allow' ? <div className="permission-limits">
            <label>{t('At most per day')}<input type="number" min={1} max={1000} placeholder={t('No limit')} disabled={!editable} value={rule.maxPerDay ?? ''} onChange={(event) => setField({ maxPerDay: numberOrUndefined(event.target.value) })} /></label>
            {tool === 'googleads_set_budget' ? <label>{t('Largest daily budget')}<input type="number" min={0} step="0.01" placeholder={t('No limit')} disabled={!editable} value={rule.maxAmount ?? ''} onChange={(event) => setField({ maxAmount: numberOrUndefined(event.target.value) })} /></label> : null}
            {tool === 'github_write_file' ? <label>{t('Only branches starting with')}<input type="text" placeholder="claude/" disabled={!editable} value={rule.branchPrefix ?? ''} onChange={(event) => setField({ branchPrefix: event.target.value || undefined })} /></label> : null}
            {tool === 'gmail_send' ? <label>{t('Only to these addresses or @domains')}<input type="text" placeholder="me@example.com, @mycompany.com" disabled={!editable} value={(rule.allowedRecipients ?? []).join(', ')} onChange={(event) => setField({ allowedRecipients: event.target.value.split(',').map((item) => item.trim()).filter(Boolean) })} /></label> : null}
          </div> : null}
        </div>
      })}
    </div>

    <ErrorBanner message={error} />
    {editable ? <div className="permission-save">
      <button className="co-primary-button" disabled={saving || !dirty} onClick={() => void save()}><Icon name="check" size={14} />{saving ? t('Saving…') : t('Save permissions')}</button>
      {saved && !dirty ? <span className="co-panel-note">{t('Saved.')}</span> : null}
    </div> : <p className="co-panel-note">{t('Only admins can change these. Anything without a rule asks for approval.')}</p>}
    <div className="co-safety-note"><Icon name="shield" /><p>{t('Anything outside a rule’s limits asks for approval. Every automatic action shows in the chat and in recent access activity.')}</p></div>
  </section>
}
