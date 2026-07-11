import { SignInButton, SignUpButton, UserButton } from '@clerk/clerk-react'
import { useCallback, useEffect, useMemo, useRef, useState, type ClipboardEvent, type FormEvent, type KeyboardEvent, type Ref } from 'react'
import './App.css'
import {
  applyDocumentImport,
  applyMiaActionDraft,
  archiveBudgetCategory,
  cancelMiaActionDraft,
  clearMiaMessages,
  confirmTransactionDraft,
  createAdminCohort,
  createAdminUser,
  createBudgetCategory,
  deleteDocumentImport,
  deleteDocumentImportSource,
  fetchAdminCohorts,
  fetchAdminUsers,
  fetchAppData,
  fetchBudget,
  fetchDocumentImport,
  fetchDocumentImportSourcePreview,
  fetchDocumentImportSourceUrl,
  fetchDocumentImports,
  fetchMiaMessages,
  fetchSpendingReport,
  ignoreTransactionDraft,
  matchTransactionDraft,
  reprocessDocumentImport,
  reopenTransactionDraft,
  resendAdminUserInvitation,
  restoreBudgetCategory,
  saveWorkspaceSetup,
  sendMiaMessage,
  transcribeMiaVoice,
  updateBudgetAllocation,
  updateAdminCohort,
  updateBudgetCategory,
  updateAdminUser,
  updateDocumentImportItem,
  updateTransactionDraft,
  uploadDocumentImport,
} from './api'
import type {
  AdminCohort,
  AdminCohortInput,
  AdminCohortStatus,
  AdminUser,
  AdminUserInput,
  AdminUserMutationResponse,
  AnnualBudgetPlan,
  AppData,
  BudgetCategoryMonth,
  BudgetCategoryRow,
  BudgetData,
  BudgetMonth,
  BudgetStackKey,
  CurrentUser,
  DocumentImportItem,
  DocumentImportItemInput,
  DocumentImportKind,
  DocumentSourcePreview as DocumentSourcePreviewData,
  DocumentSourceUrl,
  FinancialDocumentImport,
  InvitationStatus,
  MiaActionDraft,
  MiaActionItem,
  MiaMessage,
  MiaMessageAttachment,
  RecentTransaction,
  SpendingReport,
  TransactionDraft,
  TransactionDraftUpdateInput,
  UserRole,
  WorkspaceSetupValues,
} from './api'
import { SeoManager } from './components/SeoManager'
import { useAuthContext } from './contexts/authContextValue'
import { captureAnalyticsEvent, captureSectionPageview, trackDocumentUpload } from './lib/analytics'

const currency = new Intl.NumberFormat('en-US', {
  style: 'currency',
  currency: 'USD',
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
})

const sections = ['Home', 'Ask Mia', 'My Profile', 'Budget', 'Wealth', 'CFO Filter', 'Optionality']
const ADMIN_SECTION = 'Admin'
const allSections = [...sections, ADMIN_SECTION]
const MIA_CHAT_STORAGE_PREFIX = 'household-cfo:mia-chat:v1'
const MIA_MESSAGE_MAX_LENGTH = 2_000
const DEMO_MIA_STORAGE_MAX_MESSAGES = 100
const SUPPORTED_DOCUMENT_ACCEPTS = '.xlsx,.xls,.csv,.pdf,.docx,.jpg,.jpeg,.png,.webp,.heic,.heif,image/*,image/jpeg,image/png,image/webp,image/heic,image/heif,application/pdf,text/csv'
const MAX_CHAT_ATTACHMENTS = 5
const PROCESSING_IMPORT_STATUSES = new Set(['uploaded', 'processing'])
const REVIEWABLE_IMPORT_STATUSES = new Set(['needs_review', 'partially_applied'])
const VOICE_MIME_TYPES = ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4', 'audio/ogg;codecs=opus']

function preferredVoiceMimeType() {
  if (typeof MediaRecorder === 'undefined' || typeof MediaRecorder.isTypeSupported !== 'function') return undefined

  return VOICE_MIME_TYPES.find((mimeType) => MediaRecorder.isTypeSupported(mimeType))
}

type PendingMiaAttachment = {
  id: string
  file: File
  filename: string
  content_type: string
  document_kind: DocumentImportKind
  previewUrl: string
  document_import_id?: number
  status?: FinancialDocumentImport['status']
  source_available?: boolean
}

type BudgetAllocationChange = {
  allocation_id: number
  planned_amount: string
  category_id: number
  stack_key: BudgetStackKey
}

type BudgetCategoryChange = {
  id: number
  name: string
  stack_key: BudgetStackKey
}

type BudgetEditChanges = {
  allocations: BudgetAllocationChange[]
  categories: BudgetCategoryChange[]
}

const documentUploadCards: Array<{
  kind: DocumentImportKind
  label: string
  eyebrow: string
  accepts: string
  helper: string
}> = [
  {
    kind: 'spreadsheet',
    label: 'Budget file',
    eyebrow: 'Expense stack',
    accepts: '.xlsx,.xls,.csv,.pdf,.docx',
    helper: 'Upload an Excel workbook, CSV, PDF, or Word budget. Mia drafts income, expenses, assets, and debts for review.',
  },
  {
    kind: 'statement',
    label: 'Bank or card statement',
    eyebrow: 'Fresh balances',
    accepts: '.pdf,.xlsx,.xls,.csv,.jpg,.jpeg,.png,.webp,.heic,.heif,image/*',
    helper: 'Upload a PDF, CSV, spreadsheet, or statement screenshot to stage transaction rows, propose matches, and reconcile actuals by month.',
  },
  {
    kind: 'pay_stub',
    label: 'Pay stub',
    eyebrow: 'Income proof',
    accepts: '.pdf,.docx,.jpg,.jpeg,.png,.webp,.heic,.heif,image/*',
    helper: 'Upload a pay stub photo or PDF to draft take-home income. You approve before it becomes official.',
  },
  {
    kind: 'receipt',
    label: 'Receipt or quick evidence',
    eyebrow: 'Quick evidence',
    accepts: '.pdf,.jpg,.jpeg,.png,.webp,.heic,.heif,image/*',
    helper: 'Upload a receipt, PDF, or photo so Mia can draft a reviewable transaction, including split receipts like groceries plus cigarettes.',
  },
]

const sourceDerivedCopy = [
  'Expense Stack',
  'Non-discretionary',
  'Sinking Fund — Expected',
  'Sinking Fund — Unexpected',
  'Upload spreadsheet',
  'Upload statement',
  'Upload pay stub',
  'Approved data loaded',
]

const statusCopy = {
  green: 'steady',
  yellow: 'watch',
  red: 'pause',
  blue: 'context',
  gold: 'build',
} as Record<string, string>

function App() {
  const auth = useAuthContext()
  const canLoadWorkspace = !auth.isClerkEnabled || Boolean(auth.currentUser)
  const [data, setData] = useState<AppData | null>(null)
  const [setupDraft, setSetupDraft] = useState<WorkspaceSetupValues | null>(null)
  const [isProfileEditing, setIsProfileEditing] = useState(false)
  const [setupSaving, setSetupSaving] = useState(false)
  const [setupError, setSetupError] = useState<string | null>(null)
  const [active, setActive] = useState(() => {
    const hashSection = decodeURIComponent(window.location.hash.replace('#', ''))
    return allSections.includes(hashSection) ? hashSection : sections[0]
  })
  const [messages, setMessages] = useState<MiaMessage[]>([])
  const [question, setQuestion] = useState('')
  const [miaLoading, setMiaLoading] = useState(false)
  const [miaClearing, setMiaClearing] = useState(false)
  const [confirmClearChat, setConfirmClearChat] = useState(false)
  const [miaError, setMiaError] = useState<string | null>(null)
  const [budgetAction, setBudgetAction] = useState<string | null>(null)
  const [budgetError, setBudgetError] = useState<string | null>(null)
  const [budgetView, setBudgetView] = useState<{ year: number; monthIndex: number } | null>(null)
  const [spendingReport, setSpendingReport] = useState<SpendingReport | null>(null)
  const [spendingReportLoading, setSpendingReportLoading] = useState(false)
  const [spendingReportError, setSpendingReportError] = useState<string | null>(null)
  const [newBudgetCategory, setNewBudgetCategory] = useState<{ name: string; stack_key: BudgetStackKey; monthly_amount: string }>({
    name: '',
    stack_key: 'discretionary',
    monthly_amount: '',
  })
  const [isChatExpanded, setIsChatExpanded] = useState(false)
  const [showChatScrollButton, setShowChatScrollButton] = useState(false)
  const [voiceRecording, setVoiceRecording] = useState(false)
  const [voiceTranscribing, setVoiceTranscribing] = useState(false)
  const [voiceNotice, setVoiceNotice] = useState<string | null>(null)
  const [documentImports, setDocumentImports] = useState<FinancialDocumentImport[]>([])
  const [documentsLoading, setDocumentsLoading] = useState(false)
  const [documentsError, setDocumentsError] = useState<string | null>(null)
  const [documentsNotice, setDocumentsNotice] = useState<string | null>(null)
  const [uploadingKind, setUploadingKind] = useState<DocumentImportKind | null>(null)
  const [pendingMiaAttachments, setPendingMiaAttachments] = useState<PendingMiaAttachment[]>([])
  const pendingMiaAttachmentsRef = useRef<PendingMiaAttachment[]>([])
  const [previewAttachment, setPreviewAttachment] = useState<PendingMiaAttachment | null>(null)
  const [selectedImportId, setSelectedImportId] = useState<number | null>(null)
  const [itemSavingIds, setItemSavingIds] = useState<Set<number>>(() => new Set())
  const [documentAction, setDocumentAction] = useState<string | null>(null)
  const [expandedAppliedImportId, setExpandedAppliedImportId] = useState<number | null>(null)
  const [previewImport, setPreviewImport] = useState<FinancialDocumentImport | null>(null)
  const miaAttachmentInputRef = useRef<HTMLInputElement | null>(null)
  const setupFormRef = useRef<HTMLFormElement | null>(null)
  const documentImportsRef = useRef<HTMLElement | null>(null)
  const [error, setError] = useState<string | null>(null)
  const chatStorageKey = useMemo(() => {
    const owner = auth.currentUser?.id ? `user-${auth.currentUser.id}` : 'preview'
    return `${MIA_CHAT_STORAGE_PREFIX}:${owner}`
  }, [auth.currentUser?.id])
  const [messagesStorageKey, setMessagesStorageKey] = useState(chatStorageKey)
  const chatCardRef = useRef<HTMLElement | null>(null)
  const composerRef = useRef<HTMLTextAreaElement | null>(null)
  const mediaRecorderRef = useRef<MediaRecorder | null>(null)
  const voiceStreamRef = useRef<MediaStream | null>(null)
  const voiceChunksRef = useRef<Blob[]>([])
  const lastTrackedSectionRef = useRef<string | null>(null)
  const lastWorkspaceDraftSignatureRef = useRef<string | null>(null)
  const currentMessages = messagesStorageKey === chatStorageKey ? messages : []
  const shouldUseRealWorkspace = auth.isClerkEnabled
  const isRealWorkspace = data?.workspace?.mode === 'real'
  const workspaceLoadKey = data ? `${data.workspace?.mode ?? 'unknown'}:${data.workspace?.household_id ?? 'demo'}` : ''
  const visibleSections = useMemo(() => (auth.currentUser?.is_admin ? [...sections, ADMIN_SECTION] : sections), [auth.currentUser?.is_admin])
  const activeSection = active === ADMIN_SECTION && auth.currentUser && !auth.currentUser.is_admin ? sections[0] : active
  const selectedImport = useMemo(() => {
    const explicitImport = selectedImportId ? documentImports.find((documentImport) => documentImport.id === selectedImportId) : null
    return explicitImport ?? documentImports.find((documentImport) => documentImport.status === 'needs_review') ?? documentImports[0] ?? null
  }, [documentImports, selectedImportId])
  const pendingImportsCount = useMemo(
    () => documentImports.filter((documentImport) => documentImport.status === 'needs_review').length,
    [documentImports],
  )
  const processingImportsCount = useMemo(
    () => documentImports.filter((documentImport) => PROCESSING_IMPORT_STATUSES.has(documentImport.status)).length,
    [documentImports],
  )
  const pendingTransactionDrafts = data?.budget.annual_plan?.pending_transaction_drafts ?? []
  const pendingMiaActionDrafts = data?.budget.annual_plan?.pending_mia_action_drafts ?? []
  const activeBudgetPlan = data?.budget.annual_plan
  const selectedBudgetYear = budgetView?.year ?? activeBudgetPlan?.year ?? new Date().getFullYear()
  const selectedBudgetMonthIndex = Math.max(0, Math.min(11, budgetView?.monthIndex ?? (selectedBudgetYear === new Date().getFullYear() ? new Date().getMonth() : 0)))
  const selectedBudgetMonth = activeBudgetPlan?.year === selectedBudgetYear ? activeBudgetPlan.months[selectedBudgetMonthIndex] : null
  const selectedBudgetMonthStartsOn = selectedBudgetMonth?.starts_on ?? null
  const selectedBudgetMonthEndsOn = selectedBudgetMonth?.ends_on ?? null
  useEffect(() => {
    pendingMiaAttachmentsRef.current = pendingMiaAttachments
  }, [pendingMiaAttachments])

  const documentStatusSignature = useMemo(
    () => documentImports
      .filter((documentImport) => PROCESSING_IMPORT_STATUSES.has(documentImport.status))
      .map((documentImport) => `${documentImport.id}:${documentImport.status}`)
      .join('|'),
    [documentImports],
  )
  const importDraftSignature = useMemo(
    () => documentImports
      .flatMap((documentImport) => documentImport.transaction_drafts.map((draft) => `${documentImport.id}:${draft.id}:${draft.status}:${draft.amount_cents ?? draft.amount}`))
      .sort()
      .join('|'),
    [documentImports],
  )

  useEffect(() => {
    if (!data) return

    const signature = `${activeSection}:${data.workspace?.mode ?? 'demo'}:${auth.currentUser?.role ?? 'preview'}`
    if (lastTrackedSectionRef.current === signature) return

    captureSectionPageview(activeSection, {
      workspace_mode: data.workspace?.mode ?? 'demo',
      auth_mode: auth.isClerkEnabled ? 'clerk' : 'preview',
      app_role: auth.currentUser?.role ?? 'preview',
      profile_complete: data.profile.completeness,
      pending_imports: pendingImportsCount,
      processing_imports: processingImportsCount,
    })
    lastTrackedSectionRef.current = signature
  }, [activeSection, auth.currentUser?.role, auth.isClerkEnabled, data, pendingImportsCount, processingImportsCount])

  const refreshDocumentImports = useCallback(async ({ quiet = false }: { quiet?: boolean } = {}) => {
    if (!isRealWorkspace) {
      setDocumentImports([])
      setSelectedImportId(null)
      return
    }

    if (!quiet) {
      setDocumentsLoading(true)
      setDocumentsError(null)
    }

    try {
      const imports = await fetchDocumentImports()
      setDocumentImports((current) => mergeImportSummariesWithDetails(imports, current))
    } catch (caught) {
      if (!quiet) {
        setDocumentsError(caught instanceof Error ? caught.message : 'Document imports could not be loaded.')
      }
    } finally {
      if (!quiet) setDocumentsLoading(false)
    }
  }, [isRealWorkspace])

  const refreshMiaMessages = useCallback(async ({ quiet = true }: { quiet?: boolean } = {}) => {
    if (!isRealWorkspace || miaLoading) return

    try {
      const mia = await fetchMiaMessages(true)
      setMessagesStorageKey(chatStorageKey)
      setMessages(mia.messages)
    } catch (caught) {
      if (!quiet) setMiaError(caught instanceof Error ? caught.message : 'Mia chat could not be refreshed.')
    }
  }, [chatStorageKey, isRealWorkspace, miaLoading])

  const refreshSpendingReport = useCallback(async ({ startsOn = selectedBudgetMonthStartsOn, endsOn = selectedBudgetMonthEndsOn, quiet = true }: { startsOn?: string | null; endsOn?: string | null; quiet?: boolean } = {}) => {
    if (!isRealWorkspace || !startsOn || !endsOn) {
      if (!isRealWorkspace) setSpendingReport(null)
      return
    }

    if (!quiet) {
      setSpendingReportLoading(true)
      setSpendingReportError(null)
    }

    try {
      const report = await fetchSpendingReport(startsOn, endsOn)
      setSpendingReport(report)
    } catch (caught) {
      setSpendingReportError(caught instanceof Error ? caught.message : 'Spending report could not be loaded.')
    } finally {
      if (!quiet) setSpendingReportLoading(false)
    }
  }, [isRealWorkspace, selectedBudgetMonthEndsOn, selectedBudgetMonthStartsOn])

  function refreshSpendingReportForBudget(budget: BudgetData | null | undefined, monthIndex = selectedBudgetMonthIndex) {
    const month = budget?.annual_plan?.months[monthIndex]
    if (!month) return

    void refreshSpendingReport({ startsOn: month.starts_on, endsOn: month.ends_on })
  }

  useEffect(() => {
    if (!canLoadWorkspace) return

    let cancelled = false

    fetchAppData(shouldUseRealWorkspace)
      .then((payload) => {
        if (cancelled) return
        const realWorkspace = payload.workspace?.mode === 'real'
        const restoredMessages = realWorkspace ? payload.mia.messages : loadStoredMiaMessages(chatStorageKey)
        setMessagesStorageKey(chatStorageKey)
        setData(payload)
        setSetupDraft(payload.workspace?.setup_values ?? null)
        setMessages(restoredMessages)
      })
      .catch(() => {
        if (cancelled) return
        setError('Mia’s workspace is offline for a moment. Start the Rails API on port 3000 to load preview data.')
      })

    return () => {
      cancelled = true
    }
  }, [canLoadWorkspace, chatStorageKey, shouldUseRealWorkspace])

  useEffect(() => {
    if (!workspaceLoadKey) return

    let cancelled = false
    queueMicrotask(() => {
      if (!cancelled) void refreshDocumentImports()
    })

    return () => {
      cancelled = true
    }
  }, [refreshDocumentImports, workspaceLoadKey])

  useEffect(() => {
    if (!isRealWorkspace || !selectedImport || selectedImport.details_included) return

    let cancelled = false
    const importId = selectedImport.id
    fetchDocumentImport(importId)
      .then((documentImport) => {
        if (cancelled) return
        setDocumentImports((current) => replaceImport(current, documentImport))
      })
      .catch((caught) => {
        if (!cancelled) setDocumentsError(caught instanceof Error ? caught.message : 'Document review details could not be loaded.')
      })

    return () => {
      cancelled = true
    }
  }, [isRealWorkspace, selectedImport])

  useEffect(() => {
    if (!isRealWorkspace) return

    function refreshIfVisible() {
      if (document.visibilityState === 'hidden') return
      void refreshMiaMessages()
    }

    const intervalId = window.setInterval(refreshIfVisible, activeSection === 'Ask Mia' ? 5000 : 15000)
    window.addEventListener('focus', refreshIfVisible)
    document.addEventListener('visibilitychange', refreshIfVisible)

    return () => {
      window.clearInterval(intervalId)
      window.removeEventListener('focus', refreshIfVisible)
      document.removeEventListener('visibilitychange', refreshIfVisible)
    }
  }, [activeSection, isRealWorkspace, refreshMiaMessages])

  useEffect(() => {
    if (!isRealWorkspace || !documentStatusSignature) return

    const intervalId = window.setInterval(() => {
      void refreshDocumentImports({ quiet: true })
    }, 3500)

    return () => window.clearInterval(intervalId)
  }, [documentStatusSignature, isRealWorkspace, refreshDocumentImports])

  useEffect(() => {
    if (!isRealWorkspace || !importDraftSignature || miaLoading) return
    if (lastWorkspaceDraftSignatureRef.current === importDraftSignature) return

    const signature = importDraftSignature
    let cancelled = false
    fetchAppData(true)
      .then((payload) => {
        if (cancelled) return
        lastWorkspaceDraftSignatureRef.current = signature
        setData(payload)
        setSetupDraft((current) => payload.workspace?.setup_values ?? current)
        setMessagesStorageKey(chatStorageKey)
        setMessages(payload.mia.messages)
      })
      .catch(() => {
        // Polling will retry; document review cards remain available from import summaries.
      })

    return () => {
      cancelled = true
    }
  }, [chatStorageKey, importDraftSignature, isRealWorkspace, miaLoading])

  useEffect(() => {
    if (!isRealWorkspace || !selectedBudgetMonthStartsOn || !selectedBudgetMonthEndsOn) return

    const startsOn = selectedBudgetMonthStartsOn
    const endsOn = selectedBudgetMonthEndsOn
    let cancelled = false
    async function loadSpendingReport() {
      setSpendingReportLoading(true)
      setSpendingReportError(null)
      try {
        const report = await fetchSpendingReport(startsOn, endsOn)
        if (!cancelled) setSpendingReport(report)
      } catch (caught) {
        if (!cancelled) setSpendingReportError(caught instanceof Error ? caught.message : 'Spending report could not be loaded.')
      } finally {
        if (!cancelled) setSpendingReportLoading(false)
      }
    }

    void loadSpendingReport()
    return () => {
      cancelled = true
    }
  }, [isRealWorkspace, selectedBudgetMonthStartsOn, selectedBudgetMonthEndsOn])

  const surplus = useMemo(() => {
    if (!data) return 0
    return data.budget.monthly_income - data.budget.total_monthly_outflow
  }, [data])

  useEffect(() => {
    if (!data || isRealWorkspace) return
    if (messagesStorageKey !== chatStorageKey) return

    saveStoredMiaMessages(chatStorageKey, messages)
  }, [chatStorageKey, data, isRealWorkspace, messages, messagesStorageKey])

  useEffect(() => {
    document.body.classList.toggle('mia-chat-expanded', isChatExpanded)

    return () => document.body.classList.remove('mia-chat-expanded')
  }, [isChatExpanded])

  useEffect(() => {
    if (!isChatExpanded && !confirmClearChat) return

    function handleEscape(event: globalThis.KeyboardEvent) {
      if (event.key !== 'Escape') return
      if (confirmClearChat) {
        setConfirmClearChat(false)
        return
      }
      setIsChatExpanded(false)
    }

    window.addEventListener('keydown', handleEscape)
    return () => window.removeEventListener('keydown', handleEscape)
  }, [confirmClearChat, isChatExpanded])

  useEffect(() => {
    if (!previewImport && !previewAttachment) return

    function handleEscape(event: globalThis.KeyboardEvent) {
      if (event.key !== 'Escape') return
      setPreviewImport(null)
      setPreviewAttachment(null)
    }

    window.addEventListener('keydown', handleEscape)
    return () => window.removeEventListener('keydown', handleEscape)
  }, [previewAttachment, previewImport])

  const updateChatScrollAffordance = useCallback(() => {
    const chatCard = chatCardRef.current
    if (!chatCard) return

    const distanceFromBottom = chatCard.scrollHeight - chatCard.scrollTop - chatCard.clientHeight
    setShowChatScrollButton(distanceFromBottom > 72)
  }, [])

  const scrollMiaChatToBottom = useCallback((behavior: ScrollBehavior = 'smooth') => {
    const chatCard = chatCardRef.current
    if (!chatCard) return

    chatCard.scrollTo({ top: chatCard.scrollHeight, behavior })
    setShowChatScrollButton(false)
  }, [])

  useEffect(() => {
    if (activeSection !== 'Ask Mia') return

    scrollMiaChatToBottom('smooth')
  }, [activeSection, currentMessages.length, miaLoading, scrollMiaChatToBottom])

  const stopVoiceStream = useCallback(() => {
    voiceStreamRef.current?.getTracks().forEach((track) => track.stop())
    voiceStreamRef.current = null
  }, [])

  const handleVoiceRecordingComplete = useCallback(async (mimeType: string) => {
    const chunks = voiceChunksRef.current
    voiceChunksRef.current = []
    mediaRecorderRef.current = null
    stopVoiceStream()
    setVoiceRecording(false)

    if (chunks.length === 0) {
      setVoiceNotice(null)
      setMiaError("I couldn't hear anything in that recording. Try again or type the note for Mia.")
      return
    }

    setVoiceTranscribing(true)
    setVoiceNotice(null)
    try {
      const transcript = (await transcribeMiaVoice(new Blob(chunks, { type: mimeType || 'audio/webm' }))).trim()
      if (!transcript) {
        setMiaError("I couldn't turn that recording into text. Try again or type the note for Mia.")
        return
      }

      setQuestion((current) => current.trim() ? `${current.trimEnd()}\n${transcript}` : transcript)
      setVoiceNotice('Transcript ready — review it before sending. Mia will only stage drafts for you to confirm.')
      setMiaError(null)
      window.setTimeout(() => composerRef.current?.focus(), 0)
    } catch (error) {
      setMiaError(error instanceof Error ? error.message : 'Voice transcription failed. Try again or type your note for Mia.')
    } finally {
      setVoiceTranscribing(false)
    }
  }, [stopVoiceStream])

  useEffect(() => () => {
    const recorder = mediaRecorderRef.current
    if (recorder) {
      recorder.onstop = null
      if (recorder.state !== 'inactive') recorder.stop()
    }
    voiceChunksRef.current = []
    mediaRecorderRef.current = null
    stopVoiceStream()
  }, [stopVoiceStream])

  const handleVoiceButtonClick = useCallback(async () => {
    if (voiceRecording) {
      setVoiceNotice('Transcribing your recording…')
      const recorder = mediaRecorderRef.current
      if (recorder && recorder.state !== 'inactive') {
        recorder.stop()
      } else {
        setVoiceRecording(false)
      }
      return
    }

    if (!isRealWorkspace) {
      setMiaError('Sign in to a real workspace before using voice input.')
      return
    }
    if (miaLoading || voiceTranscribing) return
    if (!window.isSecureContext) {
      setMiaError('Voice input needs HTTPS on phones. Use localhost on this computer, the Netlify preview, or an HTTPS tunnel for mobile testing.')
      return
    }
    if (!navigator.mediaDevices?.getUserMedia || typeof MediaRecorder === 'undefined') {
      setMiaError('Voice input is not available in this browser. You can still type your note for Mia.')
      return
    }

    setMiaError(null)
    setVoiceNotice(null)
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true })
      voiceStreamRef.current = stream
      const mimeType = preferredVoiceMimeType()
      const recorder = new MediaRecorder(stream, mimeType ? { mimeType } : undefined)
      voiceChunksRef.current = []
      mediaRecorderRef.current = recorder
      recorder.ondataavailable = (event) => {
        if (event.data.size > 0) voiceChunksRef.current.push(event.data)
      }
      recorder.onstop = () => {
        void handleVoiceRecordingComplete(recorder.mimeType || mimeType || 'audio/webm')
      }
      recorder.onerror = () => {
        recorder.onstop = null
        voiceChunksRef.current = []
        mediaRecorderRef.current = null
        setMiaError('Voice recording stopped unexpectedly. Try again or type your note for Mia.')
        setVoiceRecording(false)
        setVoiceTranscribing(false)
        setVoiceNotice(null)
        stopVoiceStream()
      }
      recorder.start()
      setVoiceRecording(true)
      setVoiceNotice('Recording. Tap stop when you are done speaking.')
    } catch (error) {
      stopVoiceStream()
      setVoiceRecording(false)
      setMiaError(error instanceof Error ? error.message : 'Microphone access was blocked. Allow microphone access or type your note for Mia.')
    }
  }, [handleVoiceRecordingComplete, isRealWorkspace, miaLoading, stopVoiceStream, voiceRecording, voiceTranscribing])

  function switchSection(section: string) {
    captureAnalyticsEvent('section_selected', {
      section: section.toLowerCase().replace(/[^a-z0-9]+/g, '_'),
      from_section: activeSection.toLowerCase().replace(/[^a-z0-9]+/g, '_'),
    })
    setActive(section)
    if (section !== 'Ask Mia') setIsChatExpanded(false)
    window.history.replaceState(null, '', `#${encodeURIComponent(section)}`)
  }

  async function handleAskMia(prompt = question) {
    const cleanPrompt = prompt.trim()
    const attachmentsToSend = pendingMiaAttachments.map((attachment) => attachmentWithMessageContext(attachment, cleanPrompt))
    if ((!cleanPrompt && attachmentsToSend.length === 0) || miaLoading) return
    if (cleanPrompt.length > MIA_MESSAGE_MAX_LENGTH) {
      setMiaError(`Mia messages must stay under ${MIA_MESSAGE_MAX_LENGTH.toLocaleString()} characters.`)
      return
    }
    if (attachmentsToSend.length > 0 && !isRealWorkspace) {
      setMiaError('Sign in to a real workspace before attaching documents.')
      return
    }

    const messageContent = cleanPrompt || 'Please review this upload.'
    const optimisticMessageId = clientSideId('mia-message')
    setMiaLoading(true)
    setMiaError(null)
    setQuestion('')
    setPendingMiaAttachments([])
    pendingMiaAttachmentsRef.current = []
    const priorMessages = currentMessages
    const optimisticMessage: MiaMessage = {
      client_id: optimisticMessageId,
      role: 'user',
      author: 'You',
      content: messageContent,
      attachments: attachmentsToSend.map(localAttachmentForMessage),
    }
    setMessages((current) => [...current, optimisticMessage])

    let preparedAttachmentsForRetry = attachmentsToSend

    try {
      const uploadResult = await uploadPendingMiaAttachments(attachmentsToSend)
      preparedAttachmentsForRetry = uploadResult.attachments
      const readyAttachments = await waitForMiaAttachmentImports(uploadResult.attachments)
      preparedAttachmentsForRetry = readyAttachments
      const response = await sendMiaMessage(
        messageContent,
        priorMessages,
        isRealWorkspace,
        selectedBudgetYear,
        selectedBudgetMonthIndex + 1,
        readyAttachments.filter((attachment) => attachment.document_import_id).map((attachment) => attachment.document_import_id!),
      )
      captureAnalyticsEvent('mia_message_sent', {
        workspace_mode: isRealWorkspace ? 'real' : 'demo',
        history_count: priorMessages.length,
        prompt_length_bucket: messageLengthBucket(messageContent.length),
        attachment_count: attachmentsToSend.length,
      })
      if (response.budget) {
        setData((current) => current ? { ...current, budget: response.budget! } : current)
        const responseMonthIndex = response.transaction_draft ? monthIndexFromIsoDate(response.transaction_draft.occurred_on) : selectedBudgetMonthIndex
        if (response.transaction_draft && response.budget.annual_plan) {
          setBudgetView({ year: response.budget.annual_plan.year, monthIndex: responseMonthIndex })
        }
        refreshSpendingReportForBudget(response.budget, responseMonthIndex)
      }
      if (response.spending_report) {
        setSpendingReport(response.spending_report)
      }
      if (attachmentsToSend.length > 0) void refreshDocumentImports({ quiet: true })
      const userMessageWithPreviews = attachLocalPreviewsToMessage(response.user_message, readyAttachments)
      setMessages((current) => [...current.slice(0, -1), userMessageWithPreviews, response.assistant_message])
      if (response.transaction_draft) {
        captureAnalyticsEvent('transaction_draft_presented_in_chat', {
          source_type: response.transaction_draft.source_type ?? 'manual_chat',
        })
      }
      if (response.mia_action_draft) {
        captureAnalyticsEvent('mia_action_draft_presented', {
          draft_type: response.mia_action_draft.draft_type,
          item_count: response.mia_action_draft.items.length,
        })
      }
    } catch (caught) {
      captureAnalyticsEvent('mia_message_failed', {
        workspace_mode: isRealWorkspace ? 'real' : 'demo',
        history_count: priorMessages.length,
        prompt_length_bucket: messageLengthBucket(messageContent.length),
        attachment_count: attachmentsToSend.length,
      })
      setMessages((current) => current.filter((message) => message.client_id !== optimisticMessageId))
      setMiaError(caught instanceof Error ? caught.message : 'Mia could not send that message. Please try again.')
      const retryAttachments = caught instanceof MiaAttachmentError ? caught.attachments : preparedAttachmentsForRetry
      setPendingMiaAttachments((current) => [...retryAttachments, ...current])
    } finally {
      setMiaLoading(false)
      requestAnimationFrame(() => composerRef.current?.focus({ preventScroll: true }))
    }
  }

  function handleAskMiaSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    void handleAskMia()
  }

  function handleAskMiaKeyDown(event: KeyboardEvent<HTMLTextAreaElement>) {
    if (event.key !== 'Enter' || event.shiftKey) return

    event.preventDefault()
    void handleAskMia()
  }

  function handleClearMessagesRequest() {
    if (miaClearing || currentMessages.length === 0) return

    setConfirmClearChat(true)
  }

  async function handleClearMessages() {
    if (miaClearing) return

    setConfirmClearChat(false)
    setMiaClearing(true)
    setMiaError(null)
    try {
      if (isRealWorkspace) await clearMiaMessages(true)
      setMessages([])
      captureAnalyticsEvent('mia_chat_cleared', {
        workspace_mode: isRealWorkspace ? 'real' : 'demo',
      })
    } catch (caught) {
      setMiaError(caught instanceof Error ? caught.message : 'Mia chat could not be cleared. Please try again.')
    } finally {
      setMiaClearing(false)
    }
  }

  async function handleCreateBudgetCategory(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!isRealWorkspace || !data) {
      setBudgetError('Sign in to a real workspace before editing the annual budget.')
      return
    }
    if (!newBudgetCategory.name.trim()) {
      setBudgetError('Add a category name first.')
      return
    }

    setBudgetAction('create-category')
    setBudgetError(null)
    try {
      const budget = await createBudgetCategory({
        name: newBudgetCategory.name,
        stack_key: newBudgetCategory.stack_key,
        monthly_amount: newBudgetCategory.monthly_amount || 0,
      }, selectedBudgetYear)
      setData((current) => current ? { ...current, budget } : current)
      refreshSpendingReportForBudget(budget)
      setNewBudgetCategory({ name: '', stack_key: 'discretionary', monthly_amount: '' })
      captureAnalyticsEvent('budget_category_created', { stack_key: newBudgetCategory.stack_key })
    } catch (caught) {
      setBudgetError(caught instanceof Error ? caught.message : 'Budget category could not be created.')
    } finally {
      setBudgetAction(null)
    }
  }

  async function handleBudgetViewChange(year: number, monthIndex: number) {
    const normalizedYear = Math.max(2000, Math.min(2100, year))
    const normalizedMonthIndex = Math.max(0, Math.min(11, monthIndex))
    const previousBudgetView = budgetView
    setBudgetView({ year: normalizedYear, monthIndex: normalizedMonthIndex })
    if (!isRealWorkspace || !data || data.budget.annual_plan?.year === normalizedYear) return

    setBudgetAction('load-budget-year')
    setBudgetError(null)
    try {
      const budget = await fetchBudget(normalizedYear)
      setData((current) => current ? { ...current, budget } : current)
    } catch (caught) {
      setBudgetView((current) => (
        current?.year === normalizedYear && current.monthIndex === normalizedMonthIndex
          ? previousBudgetView
          : current
      ))
      setBudgetError(caught instanceof Error ? caught.message : 'Budget year could not be loaded.')
    } finally {
      setBudgetAction(null)
    }
  }

  async function handleBudgetEditSave(changes: BudgetEditChanges) {
    if (!isRealWorkspace || !data || (changes.allocations.length === 0 && changes.categories.length === 0)) return

    setBudgetAction('save-budget-edits')
    setBudgetError(null)
    let latestBudget = data.budget
    let appliedChanges = 0
    try {
      for (const change of changes.categories) {
        latestBudget = await updateBudgetCategory(change.id, { name: change.name, stack_key: change.stack_key }, selectedBudgetYear)
        appliedChanges += 1
        setData((current) => current ? { ...current, budget: latestBudget } : current)
      }
      for (const change of changes.allocations) {
        latestBudget = await updateBudgetAllocation(change.allocation_id, change.planned_amount || 0)
        appliedChanges += 1
        setData((current) => current ? { ...current, budget: latestBudget } : current)
      }
      setData((current) => current ? { ...current, budget: latestBudget } : current)
      refreshSpendingReportForBudget(latestBudget)
      captureAnalyticsEvent('budget_edits_saved', {
        allocation_change_count: changes.allocations.length,
        category_change_count: changes.categories.length,
        category_count: new Set([
          ...changes.allocations.map((change) => change.category_id),
          ...changes.categories.map((change) => change.id),
        ]).size,
      })
    } catch (caught) {
      if (appliedChanges > 0) setData((current) => current ? { ...current, budget: latestBudget } : current)
      setBudgetError(caught instanceof Error ? `${caught.message} Some earlier changes may have saved; refresh before retrying.` : 'Budget edits could not be saved. Some earlier changes may have saved; refresh before retrying.')
    } finally {
      setBudgetAction(null)
    }
  }

  async function handleArchiveBudgetCategory(row: BudgetCategoryRow) {
    if (!isRealWorkspace || !data) return

    const confirmed = window.confirm(`Archive ${row.name}? It will leave active planning, but confirmed transaction history will not be deleted.`)
    if (!confirmed) return

    setBudgetAction(`archive-category:${row.id}`)
    setBudgetError(null)
    try {
      const budget = await archiveBudgetCategory(row.id, selectedBudgetYear)
      setData((current) => current ? { ...current, budget } : current)
      refreshSpendingReportForBudget(budget)
      captureAnalyticsEvent('budget_category_archived', { stack_key: row.stack_key })
    } catch (caught) {
      setBudgetError(caught instanceof Error ? caught.message : 'Budget category could not be archived.')
    } finally {
      setBudgetAction(null)
    }
  }

  async function handleRestoreBudgetCategory(categoryId: number) {
    if (!isRealWorkspace || !data) return

    setBudgetAction(`restore-category:${categoryId}`)
    setBudgetError(null)
    try {
      const budget = await restoreBudgetCategory(categoryId, selectedBudgetYear)
      setData((current) => current ? { ...current, budget } : current)
      refreshSpendingReportForBudget(budget)
      captureAnalyticsEvent('budget_category_restored', { category_id: categoryId })
    } catch (caught) {
      setBudgetError(caught instanceof Error ? caught.message : 'Budget category could not be restored.')
    } finally {
      setBudgetAction(null)
    }
  }

  async function handleApplyMiaActionDraft(draft: MiaActionDraft) {
    if (!isRealWorkspace) return

    setBudgetAction(`apply-mia-action:${draft.id}`)
    setBudgetError(null)
    setMiaError(null)
    try {
      const workspace = await applyMiaActionDraft(draft.id)
      setData(workspace)
      if (workspace.budget.annual_plan) setBudgetView({ year: workspace.budget.annual_plan.year, monthIndex: selectedBudgetMonthIndex })
      refreshSpendingReportForBudget(workspace.budget, selectedBudgetMonthIndex)
      setMessages(workspace.mia.messages)
      setMessagesStorageKey(chatStorageKey)
      captureAnalyticsEvent('mia_action_draft_applied', {
        draft_type: draft.draft_type,
        item_count: draft.items.length,
      })
    } catch (caught) {
      const message = caught instanceof Error ? caught.message : 'Mia action draft could not be applied.'
      setBudgetError(message)
      setMiaError(message)
    } finally {
      setBudgetAction(null)
    }
  }

  async function handleCancelMiaActionDraft(draft: MiaActionDraft) {
    if (!isRealWorkspace) return

    setBudgetAction(`cancel-mia-action:${draft.id}`)
    setBudgetError(null)
    setMiaError(null)
    try {
      const workspace = await cancelMiaActionDraft(draft.id)
      setData(workspace)
      if (workspace.budget.annual_plan) setBudgetView({ year: workspace.budget.annual_plan.year, monthIndex: selectedBudgetMonthIndex })
      refreshSpendingReportForBudget(workspace.budget, selectedBudgetMonthIndex)
      setMessages(workspace.mia.messages)
      setMessagesStorageKey(chatStorageKey)
      captureAnalyticsEvent('mia_action_draft_canceled', {
        draft_type: draft.draft_type,
        item_count: draft.items.length,
      })
    } catch (caught) {
      const message = caught instanceof Error ? caught.message : 'Mia action draft could not be canceled.'
      setBudgetError(message)
      setMiaError(message)
    } finally {
      setBudgetAction(null)
    }
  }

  async function handleUpdateTransactionDraft(draft: TransactionDraft, values: TransactionDraftUpdateInput) {
    if (!isRealWorkspace) return

    setBudgetAction(`update-draft:${draft.id}`)
    setBudgetError(null)
    setDocumentsError(null)
    try {
      const response = await updateTransactionDraft(draft.id, values)
      const draftMonthIndex = monthIndexFromIsoDate(response.transaction_draft.occurred_on)
      setData(response.workspace)
      if (response.workspace.budget.annual_plan) setBudgetView({ year: response.workspace.budget.annual_plan.year, monthIndex: draftMonthIndex })
      refreshSpendingReportForBudget(response.workspace.budget, draftMonthIndex)
      void refreshDocumentImports({ quiet: true })
    } catch (caught) {
      const message = caught instanceof Error ? caught.message : 'Transaction draft could not be updated.'
      setBudgetError(message)
      setDocumentsError(message)
      throw new Error(message, { cause: caught })
    } finally {
      setBudgetAction(null)
    }
  }

  async function handleConfirmTransactionDraft(draft: TransactionDraft) {
    if (!isRealWorkspace) return

    setBudgetAction(`confirm-draft:${draft.id}`)
    setBudgetError(null)
    setDocumentsError(null)
    try {
      const workspace = await confirmTransactionDraft(draft.id)
      const draftMonthIndex = monthIndexFromIsoDate(draft.occurred_on)
      setData(workspace)
      if (workspace.budget.annual_plan) setBudgetView({ year: workspace.budget.annual_plan.year, monthIndex: draftMonthIndex })
      refreshSpendingReportForBudget(workspace.budget, draftMonthIndex)
      void refreshDocumentImports({ quiet: true })
      setMessages(workspace.mia.messages)
      setMessagesStorageKey(chatStorageKey)
      captureAnalyticsEvent('transaction_draft_confirmed', {
        source_type: draft.source_type ?? 'manual_chat',
      })
    } catch (caught) {
      const message = caught instanceof Error ? caught.message : 'Transaction draft could not be confirmed.'
      setBudgetError(message)
      setDocumentsError(message)
    } finally {
      setBudgetAction(null)
    }
  }

  async function handleIgnoreTransactionDraft(draft: TransactionDraft) {
    if (!isRealWorkspace) return

    setBudgetAction(`ignore-draft:${draft.id}`)
    setBudgetError(null)
    setDocumentsError(null)
    try {
      const workspace = await ignoreTransactionDraft(draft.id)
      const draftMonthIndex = monthIndexFromIsoDate(draft.occurred_on)
      setData(workspace)
      if (workspace.budget.annual_plan) setBudgetView({ year: workspace.budget.annual_plan.year, monthIndex: draftMonthIndex })
      refreshSpendingReportForBudget(workspace.budget, draftMonthIndex)
      void refreshDocumentImports({ quiet: true })
      setMessages(workspace.mia.messages)
      setMessagesStorageKey(chatStorageKey)
      captureAnalyticsEvent('transaction_draft_ignored', {
        source_type: draft.source_type ?? 'manual_chat',
      })
    } catch (caught) {
      const message = caught instanceof Error ? caught.message : 'Transaction draft could not be ignored.'
      setBudgetError(message)
      setDocumentsError(message)
    } finally {
      setBudgetAction(null)
    }
  }

  async function handleMatchTransactionDraft(draft: TransactionDraft, matchId?: number) {
    if (!isRealWorkspace) return

    setBudgetAction(`match-draft:${draft.id}`)
    setBudgetError(null)
    setDocumentsError(null)
    try {
      const workspace = await matchTransactionDraft(draft.id, matchId)
      const draftMonthIndex = monthIndexFromIsoDate(draft.occurred_on)
      setData(workspace)
      if (workspace.budget.annual_plan) setBudgetView({ year: workspace.budget.annual_plan.year, monthIndex: draftMonthIndex })
      refreshSpendingReportForBudget(workspace.budget, draftMonthIndex)
      void refreshDocumentImports({ quiet: true })
      setMessages(workspace.mia.messages)
      setMessagesStorageKey(chatStorageKey)
      captureAnalyticsEvent('transaction_draft_matched', {
        source_type: draft.source_type ?? 'statement',
      })
    } catch (caught) {
      const message = caught instanceof Error ? caught.message : 'Transaction draft could not be matched.'
      setBudgetError(message)
      setDocumentsError(message)
    } finally {
      setBudgetAction(null)
    }
  }

  async function handleReopenTransactionDraft(draft: TransactionDraft) {
    if (!isRealWorkspace) return

    const confirmed = window.confirm('Reopen this draft for correction? If it created an actual transaction, that actual will be removed from month-to-date totals and the draft will return to pending review.')
    if (!confirmed) return

    setBudgetAction(`reopen-draft:${draft.id}`)
    setBudgetError(null)
    setDocumentsError(null)
    try {
      const workspace = await reopenTransactionDraft(draft.id)
      const draftMonthIndex = monthIndexFromIsoDate(draft.occurred_on)
      setData(workspace)
      if (workspace.budget.annual_plan) setBudgetView({ year: workspace.budget.annual_plan.year, monthIndex: draftMonthIndex })
      refreshSpendingReportForBudget(workspace.budget, draftMonthIndex)
      void refreshDocumentImports({ quiet: true })
      setMessages(workspace.mia.messages)
      setMessagesStorageKey(chatStorageKey)
      captureAnalyticsEvent('transaction_draft_reopened', {
        previous_status: draft.status,
        source_type: draft.source_type ?? 'manual_chat',
      })
    } catch (caught) {
      const message = caught instanceof Error ? caught.message : 'Transaction draft could not be reopened.'
      setBudgetError(message)
      setDocumentsError(message)
    } finally {
      setBudgetAction(null)
    }
  }

  async function handleDocumentUpload(kind: DocumentImportKind, file: File, origin: 'profile' | 'mia' = 'profile') {
    if (!isRealWorkspace) {
      setDocumentsError('Sign in to a real workspace before uploading financial documents.')
      return
    }

    const uploadFile = normalizedEvidenceFile(file, 0)
    setUploadingKind(kind)
    setDocumentsError(null)
    setDocumentsNotice(null)
    trackDocumentUpload(kind, 'started', uploadFile)
    try {
      const documentImport = await uploadDocumentImport(uploadFile, kind, origin)
      setDocumentImports((current) => [documentImport, ...current.filter((existing) => existing.id !== documentImport.id)])
      setSelectedImportId(documentImport.id)
      setDocumentsNotice(`${documentKindLabel(kind)} uploaded privately. Mia is extracting draft values for review.`)
      trackDocumentUpload(kind, 'succeeded', uploadFile)
      captureAnalyticsEvent('document_import_created', {
        document_kind: kind,
        origin,
        status: documentImport.status,
      })

    } catch (caught) {
      trackDocumentUpload(kind, 'failed', uploadFile)
      const uploadError = caught instanceof Error ? caught.message : 'Document could not be uploaded.'
      setDocumentsError(uploadError)
      if (origin === 'mia') setMiaError(uploadError)
    } finally {
      setUploadingKind(null)
    }
  }

  function handleMiaAttachmentChange(files: FileList | File[] | null) {
    addPendingMiaAttachments(Array.from(files ?? []))
  }

  function addPendingMiaAttachments(files: File[]) {
    if (files.length === 0) return
    if (!isRealWorkspace) {
      setMiaError('Sign in to a real workspace before attaching documents.')
      return
    }

    const normalizedFiles = files.map(normalizedEvidenceFile)
    const acceptedFiles = normalizedFiles.filter(isSupportedEvidenceFile)
    const rejectedCount = normalizedFiles.length - acceptedFiles.length
    const room = Math.max(MAX_CHAT_ATTACHMENTS - pendingMiaAttachments.length, 0)
    const accepted = acceptedFiles.slice(0, room).map(pendingMiaAttachment)
    if (rejectedCount > 0) setMiaError('That file type is not supported yet. Use PDF, CSV, Excel, Word, JPG, PNG, WEBP, HEIC, or HEIF.')
    else if (acceptedFiles.length > room) setMiaError(`Attach up to ${MAX_CHAT_ATTACHMENTS} files at a time.`)
    else setMiaError(null)

    if (accepted.length > 0) setPendingMiaAttachments((current) => [...current, ...accepted])
  }

  function removePendingMiaAttachment(id: string) {
    setPendingMiaAttachments((current) => {
      const attachment = current.find((candidate) => candidate.id === id)
      if (attachment) URL.revokeObjectURL(attachment.previewUrl)
      return current.filter((candidate) => candidate.id !== id)
    })
  }

  async function uploadPendingMiaAttachments(attachments: PendingMiaAttachment[]) {
    const preparedAttachments = [...attachments]

    for (const [index, attachment] of attachments.entries()) {
      if (attachment.document_import_id) continue

      setUploadingKind(attachment.document_kind)
      trackDocumentUpload(attachment.document_kind, 'started', attachment.file)
      try {
        const documentImport = await uploadDocumentImport(attachment.file, attachment.document_kind, 'mia')
        preparedAttachments[index] = attachmentWithDocumentImport(attachment, documentImport)
        setDocumentImports((current) => [documentImport, ...current.filter((existing) => existing.id !== documentImport.id)])
        setSelectedImportId(documentImport.id)
        trackDocumentUpload(attachment.document_kind, 'succeeded', attachment.file)
        captureAnalyticsEvent('document_import_created', {
          document_kind: attachment.document_kind,
          origin: 'mia',
          status: documentImport.status,
        })
      } catch (caught) {
        trackDocumentUpload(attachment.document_kind, 'failed', attachment.file)
        const message = caught instanceof Error ? caught.message : 'Document upload failed'
        throw new MiaAttachmentUploadError(message, preparedAttachments, { cause: caught })
      } finally {
        setUploadingKind(null)
      }
    }

    return { attachments: preparedAttachments }
  }

  async function waitForMiaAttachmentImports(attachments: PendingMiaAttachment[]) {
    let currentAttachments = [...attachments]
    let pendingIds = currentAttachments
      .filter((attachment) => attachment.document_import_id && PROCESSING_IMPORT_STATUSES.has(attachment.status ?? 'uploaded'))
      .map((attachment) => attachment.document_import_id!)
    if (pendingIds.length === 0) return currentAttachments

    const deadline = Date.now() + 20_000
    while (pendingIds.length > 0 && Date.now() < deadline) {
      await sleep(1_800)
      const refreshedImports = await Promise.all(pendingIds.map((id) => fetchDocumentImport(id)))
      setDocumentImports((current) => refreshedImports.reduce((imports, documentImport) => replaceImport(imports, documentImport), current))
      currentAttachments = currentAttachments.map((attachment) => {
        const documentImport = refreshedImports.find((candidate) => candidate.id === attachment.document_import_id)
        return documentImport ? attachmentWithDocumentImport(attachment, documentImport) : attachment
      })
      pendingIds = currentAttachments
        .filter((attachment) => attachment.document_import_id && PROCESSING_IMPORT_STATUSES.has(attachment.status ?? 'uploaded'))
        .map((attachment) => attachment.document_import_id!)
    }

    return currentAttachments
  }

  function handleMiaPaste(event: ClipboardEvent<HTMLTextAreaElement>) {
    const pastedFiles = filesFromClipboard(event.clipboardData)
    if (pastedFiles.length === 0) return

    event.preventDefault()
    addPendingMiaAttachments(pastedFiles)
  }

  async function handleDocumentItemUpdate(documentImportId: number, itemId: number, values: DocumentImportItemInput) {
    setItemSavingIds((current) => new Set(current).add(itemId))
    setDocumentsError(null)
    try {
      const item = await updateDocumentImportItem(documentImportId, itemId, values)
      setDocumentImports((current) => replaceImportItem(current, documentImportId, item))
      if (item.applied_at) {
        try {
          const refreshed = await fetchAppData(isRealWorkspace)
          setData(refreshed)
          setSetupDraft(refreshed.workspace?.setup_values ?? setupDraft)
          setMessages(refreshed.mia.messages)
          setMessagesStorageKey(chatStorageKey)
          setDocumentsNotice('Applied value updated. Dashboard and Mia context are refreshed.')
        } catch {
          setDocumentsNotice('Applied value saved. Refresh the page if the dashboard does not update immediately.')
        }
      }
    } catch (caught) {
      setDocumentsError(caught instanceof Error ? caught.message : 'Extracted value could not be updated.')
    } finally {
      setItemSavingIds((current) => {
        const next = new Set(current)
        next.delete(itemId)
        return next
      })
    }
  }

  async function handleApplyDocumentImport(documentImport: FinancialDocumentImport) {
    const itemIds = selectedApplyItemIds(documentImport)
    if (itemIds.length === 0) {
      setDocumentsError('Select at least one extracted value before applying.')
      return
    }

    setDocumentAction(`apply:${documentImport.id}`)
    setDocumentsError(null)
    setDocumentsNotice(null)
    try {
      const response = await applyDocumentImport(documentImport.id, itemIds)
      setDocumentImports((current) => replaceImport(current, response.document_import))
      setData(response.workspace)
      setSetupDraft(response.workspace.workspace?.setup_values ?? setupDraft)
      setMessages(response.workspace.mia.messages)
      setMessagesStorageKey(chatStorageKey)
      setDocumentsNotice(`${response.applied_count} approved value${response.applied_count === 1 ? '' : 's'} applied. Dashboard and Mia context are refreshed.`)
      captureAnalyticsEvent('document_import_applied', {
        document_kind: documentImport.document_kind,
        applied_count: response.applied_count,
        selected_count: itemIds.length,
        resulting_status: response.document_import.status,
      })
    } catch (caught) {
      captureAnalyticsEvent('document_import_apply_failed', {
        document_kind: documentImport.document_kind,
        selected_count: itemIds.length,
      })
      setDocumentsError(caught instanceof Error ? caught.message : 'Selected values could not be applied.')
    } finally {
      setDocumentAction(null)
    }
  }

  async function handleReprocessDocumentImport(documentImport: FinancialDocumentImport) {
    setDocumentAction(`reprocess:${documentImport.id}`)
    setDocumentsError(null)
    setDocumentsNotice(null)
    try {
      const reprocessedImport = await reprocessDocumentImport(documentImport.id)
      setDocumentImports((current) => replaceImport(current, reprocessedImport))
      setDocumentsNotice('Reprocessing started. The review panel will update when Mia finishes reading the document.')
    } catch (caught) {
      setDocumentsError(caught instanceof Error ? caught.message : 'Document could not be reprocessed.')
    } finally {
      setDocumentAction(null)
    }
  }

  async function handleDeleteDocumentSource(documentImport: FinancialDocumentImport) {
    if (!window.confirm('Delete the private source file from S3? Applied household numbers will stay saved.')) return

    setDocumentAction(`source:${documentImport.id}`)
    setDocumentsError(null)
    setDocumentsNotice(null)
    try {
      const updatedImport = await deleteDocumentImportSource(documentImport.id)
      setDocumentImports((current) => replaceImport(current, updatedImport))
      setDocumentsNotice('Private source file deleted. The extracted review record remains for audit context.')
    } catch (caught) {
      setDocumentsError(caught instanceof Error ? caught.message : 'Document source could not be deleted.')
    } finally {
      setDocumentAction(null)
    }
  }

  async function handleDeleteDocumentImport(documentImport: FinancialDocumentImport) {
    if (!window.confirm('Delete this import record and its source file? This is only available before values are applied.')) return

    setDocumentAction(`delete:${documentImport.id}`)
    setDocumentsError(null)
    setDocumentsNotice(null)
    try {
      await deleteDocumentImport(documentImport.id)
      setDocumentImports((current) => current.filter((existing) => existing.id !== documentImport.id))
      setSelectedImportId((current) => (current === documentImport.id ? null : current))
      setDocumentsNotice('Document import deleted.')
    } catch (caught) {
      setDocumentsError(caught instanceof Error ? caught.message : 'Document import could not be deleted.')
    } finally {
      setDocumentAction(null)
    }
  }

  function handleOpenDocumentSource(documentImport: FinancialDocumentImport) {
    setDocumentsError(null)
    setPreviewImport(documentImport)
  }

  async function handleOpenDocumentSourceById(documentImportId: number) {
    const existingImport = documentImports.find((documentImport) => documentImport.id === documentImportId)
    if (existingImport) {
      handleOpenDocumentSource(existingImport)
      return
    }

    setDocumentsError(null)
    try {
      const documentImport = await fetchDocumentImport(documentImportId)
      setDocumentImports((current) => replaceImport(current, documentImport))
      setPreviewImport(documentImport)
    } catch (caught) {
      setDocumentsError(caught instanceof Error ? caught.message : 'Document source could not be opened.')
    }
  }

  async function handleSetupSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!setupDraft || setupSaving) return

    setSetupSaving(true)
    setSetupError(null)
    try {
      const payload = await saveWorkspaceSetup(setupDraft)
      setData(payload)
      setSetupDraft(payload.workspace?.setup_values ?? setupDraft)
      setBudgetView((current) => {
        const responseYear = payload.budget.annual_plan?.year
        if (!responseYear) return current
        return { year: responseYear, monthIndex: current?.monthIndex ?? selectedBudgetMonthIndex }
      })
      setIsProfileEditing(false)
      setMessages(payload.mia.messages)
      setMessagesStorageKey(chatStorageKey)
      captureAnalyticsEvent('workspace_setup_saved', {
        setup_complete: payload.workspace?.setup_complete ?? false,
        workspace_mode: payload.workspace?.mode ?? 'real',
      })
    } catch (caught) {
      captureAnalyticsEvent('workspace_setup_save_failed')
      setSetupError(caught instanceof Error ? caught.message : 'Your numbers could not be saved. Please try again.')
    } finally {
      setSetupSaving(false)
    }
  }

  function updateSetupDraft(key: keyof WorkspaceSetupValues, value: string) {
    if (!isProfileEditing) return

    setSetupError(null)
    setSetupDraft((current) => {
      if (!current) return current
      if (key === 'household_name' || key === 'primary_goal') return { ...current, [key]: value }

      return { ...current, [key]: Number(value) || 0 }
    })
  }

  function cancelProfileEditing() {
    setSetupError(null)
    setSetupDraft(data?.workspace?.setup_values ?? setupDraft)
    setIsProfileEditing(false)
  }

  function handleProfileSectionEdit(sectionLabel: string) {
    if (!isRealWorkspace) return

    const appliedImport = latestFullyAppliedImport(documentImports)
    if (appliedImport) {
      setSelectedImportId(appliedImport.id)
      setExpandedAppliedImportId(appliedImport.id)
      setDocumentsNotice(`${sectionLabel} values are source-backed. I opened the applied import so you can correct the detailed records.`)
      requestAnimationFrame(() => documentImportsRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' }))
      return
    }

    const fieldName = setupFocusFieldForSection(sectionLabel)
    setIsProfileEditing(true)
    setupFormRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' })
    requestAnimationFrame(() => {
      const field = setupFormRef.current?.querySelector<HTMLInputElement | HTMLTextAreaElement>(`[name="${fieldName}"]`)
      field?.focus({ preventScroll: true })
      field?.select()
    })
  }

  if (auth.isClerkEnabled && (auth.isLoading || auth.isVerifyingApi)) {
    return <AuthStatePanel title="Verifying your Household CFO Method access" copy="Mia is checking your secure cohort invitation before opening the workspace." />
  }

  if (auth.isClerkEnabled && !auth.isSignedIn) {
    return <AuthLanding />
  }

  if (auth.isClerkEnabled && auth.authError) {
    return <AccessDenied message={auth.authError} onSignOut={auth.signOut} />
  }

  if (auth.isClerkEnabled && !auth.currentUser) {
    return <AuthStatePanel title="Preparing your workspace" copy="Your Clerk session is ready. Household CFO is waiting for the cohort invitation check to finish." />
  }

  if (!data) {
    return (
      <main className="app loading-state">
        <SeoManager section="Home" />
        <section className="hero-panel">
          <p className="eyebrow">Household CFO Method powered by VERA</p>
          <h1>Loading your first cohort workspace.</h1>
          <p>{error ?? 'Pulling first cohort preview data...'}</p>
        </section>
      </main>
    )
  }

  return (
    <main className="app">
      <SeoManager section={activeSection} />
      <header className="shell-header">
        <ul className="sr-only" aria-label="Source-derived design requirements">
          {sourceDerivedCopy.map((item) => <li key={item}>{item}</li>)}
        </ul>
        <div>
          <p className="eyebrow">Household CFO Method powered by VERA</p>
          <h1>Household CFO Method</h1>
          <p className="hero-copy">
            Run your home like the C-Suite — not the unpaid maintenance staff. Build the annual budget,
            track the running totals, and use Mia as your AI coach when the next money decision needs a CFO call.
          </p>
        </div>
        <aside className="mia-status-card">
          <span className="spark" aria-hidden="true"><MiaMark /></span>
          <strong>Your CFO workspace is ready</strong>
          <p>Mia can coach from {data.profile.completeness}% profile completeness · {data.dashboard.summary.readiness_label}</p>
          {auth.currentUser && (
            <div className="account-pill">
              <span>{auth.currentUser.full_name}</span>
              <small>{auth.currentUser.role}</small>
              <UserButton afterSignOutUrl="/" />
            </div>
          )}
          <button type="button" onClick={() => switchSection('Ask Mia')}>Ask Mia for the CFO read</button>
        </aside>
      </header>

      <nav className="tabs" aria-label="Household CFO participant sections">
        {visibleSections.map((section) => (
          <button
            key={section}
            type="button"
            className={activeSection === section ? 'active' : ''}
            onClick={() => switchSection(section)}
          >
            {section}
          </button>
        ))}
      </nav>

      {activeSection === 'Home' && (
        <section className="screen-grid home-screen">
          <ScreenHeading
            eyebrow="Home"
            title="CFO snapshot"
            copy="Check the baseline, runway, safe-to-spend, and next move before a money decision leaves the household."
          />

          <div className="status-ribbon">
            <div>
              <span>Readiness</span>
              <strong>{data.dashboard.summary.readiness_label}</strong>
            </div>
            <p>Red means stabilize basics first. Yellow means cash flow is close but runway still needs protection. Green means target runway and positive monthly surplus are both in place.</p>
          </div>

          <div className="metric-row">
            <Metric label="Monthly income" value={currency.format(data.dashboard.summary.monthly_income)} />
            <Metric label="Runway" value={`${data.dashboard.summary.runway_months} months`} />
            <Metric label="Safe to spend" value={currency.format(data.dashboard.summary.next_safe_to_spend_amount)} />
            <Metric label="Baseline surplus" value={currency.format(surplus)} />
          </div>

          <div className="two-column">
            <article className="panel coach-panel">
              <p className="eyebrow">Mia’s coach read</p>
              <h3>Make the measured CFO move.</h3>
              <p>
                You have enough stability to move with intention, but the annual plan still needs runway protection.
                The next 90 days should protect cash reserves, cover irregular expenses, and prove recurring income.
              </p>
              <button type="button" onClick={() => switchSection('Ask Mia')}>Ask Mia for my next move</button>
            </article>
            <div className="card-list">
              {data.dashboard.alerts.map((alert) => (
                <article className={`insight-card ${alert.tone}`} key={alert.title}>
                  <span>{statusCopy[alert.tone] ?? 'note'}</span>
                  <h3>{alert.title}</h3>
                  <p>{alert.body}</p>
                </article>
              ))}
            </div>
          </div>

          <article className="panel next-steps">
            <h3>This week’s household CFO rhythm</h3>
            <ol>
              {data.dashboard.next_steps.map((step) => <li key={step}>{step}</li>)}
            </ol>
          </article>
        </section>
      )}

      {activeSection === 'Ask Mia' && (
        <section className="screen-grid mia-screen">
          <ScreenHeading
            eyebrow="Ask Mia"
            title="Ask Mia for the CFO read."
            copy="Mia uses your approved household context so you can make the next call with the actual numbers in front of you."
          />

          <div className="mia-layout">
            <article className="mia-context panel">
              <div className="mia-context-heading">
                <span className="spark" aria-hidden="true"><MiaMark /></span>
                <div>
                  <span>Assistant context</span>
                  <h3>Approved data loaded</h3>
                </div>
              </div>
              <p>
                Profile, Expense Stack, annual runway, debt pressure, Optionality scenario, and approved document freshness are ready for Mia to use.
              </p>
              {isRealWorkspace ? (
                <DocumentContextCard
                  imports={documentImports}
                  pendingCount={pendingImportsCount}
                  processingCount={processingImportsCount}
                  onOpenProfile={() => switchSection('My Profile')}
                  onAttach={() => miaAttachmentInputRef.current?.click()}
                  uploading={Boolean(uploadingKind)}
                />
              ) : (
                <div className="upload-strip" aria-label="Demo-only upload affordances">
                  <button type="button" disabled title="Uploads require a signed-in real workspace.">
                    <AttachmentIcon />
                    Spreadsheet import demo-only
                  </button>
                  <button type="button" disabled title="Uploads require a signed-in real workspace.">
                    <StatementIcon />
                    Statement import demo-only
                  </button>
                </div>
              )}
            </article>

            <section className={`mia-chat-shell ${isChatExpanded ? 'is-expanded' : ''}`} aria-label="Ask Mia conversation">
              <div className="chat-shell-header">
                <span className="message-avatar" aria-hidden="true">M</span>
                <div className="chat-shell-copy">
                  <h3>Ask Mia</h3>
                  <p>Plain-English coaching while you stay the CFO.</p>
                </div>
                <div className="chat-actions">
                  {currentMessages.length > 0 && (
                    <button type="button" className="chat-clear-button" onClick={handleClearMessagesRequest} disabled={miaClearing}>
                      {miaClearing ? 'Clearing' : 'Clear'}
                    </button>
                  )}
                  <button
                    type="button"
                    className="chat-expand-button"
                    aria-label={isChatExpanded ? 'Collapse Ask Mia chat' : 'Expand Ask Mia chat'}
                    aria-pressed={isChatExpanded}
                    title={isChatExpanded ? 'Collapse Ask Mia chat' : 'Expand Ask Mia chat'}
                    onClick={() => setIsChatExpanded((expanded) => !expanded)}
                  >
                    {isChatExpanded ? <CollapseIcon /> : <ExpandIcon />}
                  </button>
                </div>
              </div>

              <div className="quick-prompts chat-prompts" aria-label="Suggested questions for Mia">
                {data.mia.quick_prompts.map((prompt) => (
                  <button type="button" key={prompt} onClick={() => void handleAskMia(prompt)} disabled={miaLoading}>
                    {prompt}
                  </button>
                ))}
              </div>

              <div className="chat-card-wrap">
                <article className="chat-card" ref={chatCardRef} aria-live="polite" aria-busy={miaLoading} onScroll={updateChatScrollAffordance}>
                  {currentMessages.length === 0 && !miaLoading && (
                    <div className="empty-chat-state">
                      <span className="message-avatar" aria-hidden="true">M</span>
                      <h3>Mia is ready when you are.</h3>
                      <p>Ask what you need to decide next. Mia will use the approved household context already loaded here.</p>
                    </div>
                  )}
                  {currentMessages.map((message, index) => (
                    <div className={`message-row ${message.role}`} key={messageKey(message, index)}>
                      {message.role === 'assistant' && <span className="message-avatar" aria-hidden="true">M</span>}
                      <div className={`message ${message.role}`}>
                        <strong>{message.author}</strong>
                        {messageParagraphs(message).map((paragraph, paragraphIndex) => (
                          <p key={`${message.author}-${index}-${paragraphIndex}`}>{paragraph}</p>
                        ))}
                        {(message.attachments ?? []).length > 0 && (
                          <MessageAttachmentList
                            attachments={message.attachments ?? []}
                            imports={documentImports}
                            onOpenLocal={(attachment) => {
                              if (!attachment.preview_url) return
                              setPreviewAttachment({
                                id: `message-${attachment.filename}`,
                                file: new File([], attachment.filename, { type: attachment.content_type }),
                                filename: attachment.filename,
                                content_type: attachment.content_type,
                                document_kind: attachment.document_kind,
                                previewUrl: attachment.preview_url,
                              })
                            }}
                            onOpenImport={handleOpenDocumentSource}
                            onOpenImportId={(id) => void handleOpenDocumentSourceById(id)}
                          />
                        )}
                      </div>
                    </div>
                  ))}
                  {miaLoading && (
                    <div className="message-row assistant typing-row">
                      <span className="message-avatar" aria-hidden="true">M</span>
                      <div className="message assistant">
                        <strong>Mia</strong>
                        <div className="typing-dots" aria-label="Mia is thinking">
                          <span />
                          <span />
                          <span />
                        </div>
                      </div>
                    </div>
                  )}
                </article>
                {showChatScrollButton && currentMessages.length > 0 && (
                  <button
                    type="button"
                    className="chat-scroll-bottom-button"
                    aria-label="Scroll to latest Mia message"
                    onClick={() => scrollMiaChatToBottom()}
                  >
                    <ScrollDownIcon />
                    <span>Latest</span>
                  </button>
                )}
              </div>

              {pendingMiaActionDrafts.length > 0 && (
                <MiaActionDraftReviewStack
                  drafts={pendingMiaActionDrafts}
                  isRealWorkspace={Boolean(isRealWorkspace)}
                  action={budgetAction}
                  compact
                  onApply={handleApplyMiaActionDraft}
                  onCancel={handleCancelMiaActionDraft}
                />
              )}

              {pendingTransactionDrafts.length > 0 && (
                <TransactionDraftReviewStack
                  drafts={pendingTransactionDrafts}
                  isRealWorkspace={Boolean(isRealWorkspace)}
                  action={budgetAction}
                  compact
                  categories={activeBudgetPlan?.rows ?? []}
                  onUpdate={handleUpdateTransactionDraft}
                  onMatch={handleMatchTransactionDraft}
                  onConfirm={handleConfirmTransactionDraft}
                  onIgnore={handleIgnoreTransactionDraft}
                  onReopen={handleReopenTransactionDraft}
                />
              )}

              {miaError && <p className="chat-error" role="alert">{miaError}</p>}
              {voiceNotice && <p className={`voice-status${voiceRecording ? ' is-recording' : ''}`} role="status">{voiceNotice}</p>}

              <form className="ask-row" onSubmit={handleAskMiaSubmit}>
                <input
                  type="file"
                  className="sr-only"
                  accept={SUPPORTED_DOCUMENT_ACCEPTS}
                  multiple
                  ref={miaAttachmentInputRef}
                  onChange={(event) => {
                    handleMiaAttachmentChange(event.target.files)
                    event.currentTarget.value = ''
                  }}
                />
                {pendingMiaAttachments.length > 0 && (
                  <PendingAttachmentTray
                    attachments={pendingMiaAttachments}
                    onPreview={setPreviewAttachment}
                    onRemove={removePendingMiaAttachment}
                  />
                )}
                <button
                  className="composer-attach"
                  type="button"
                  disabled={!isRealWorkspace || Boolean(uploadingKind) || miaLoading || voiceRecording || voiceTranscribing}
                  title={isRealWorkspace ? 'Attach a receipt, screenshot, statement, or budget file for review' : 'Sign in to a real workspace before uploading documents.'}
                  aria-label="Attach receipt, screenshot, statement, or budget file"
                  onClick={() => miaAttachmentInputRef.current?.click()}
                >
                  <AttachmentIcon />
                </button>
                <button
                  className={`composer-voice${voiceRecording ? ' is-recording' : ''}`}
                  type="button"
                  disabled={!isRealWorkspace || miaLoading || voiceTranscribing}
                  title={isRealWorkspace ? (voiceRecording ? 'Stop recording and transcribe' : 'Record a voice note for Mia') : 'Sign in to a real workspace before using voice input.'}
                  aria-label={voiceRecording ? 'Stop voice recording' : 'Record voice note for Mia'}
                  aria-pressed={voiceRecording}
                  onClick={() => void handleVoiceButtonClick()}
                >
                  {voiceRecording ? <StopIcon /> : <MicrophoneIcon />}
                </button>
                <textarea
                  value={question}
                  onChange={(event) => {
                    setMiaError(null)
                    setVoiceNotice(null)
                    setQuestion(event.target.value)
                  }}
                  onKeyDown={handleAskMiaKeyDown}
                  onPaste={handleMiaPaste}
                  aria-label="Ask Mia"
                  placeholder={voiceTranscribing ? 'Transcribing your voice note...' : 'Ask Mia or attach evidence...'}
                  rows={1}
                  maxLength={MIA_MESSAGE_MAX_LENGTH}
                  ref={composerRef}
                />
                <button
                  className="send-button"
                  type="submit"
                  disabled={miaLoading || voiceRecording || voiceTranscribing || (!question.trim() && pendingMiaAttachments.length === 0)}
                  aria-label={miaLoading ? 'Mia is thinking' : 'Send message to Mia'}
                >
                  <span>{miaLoading ? 'Thinking' : 'Send'}</span>
                  <SendIcon />
                </button>
              </form>
            </section>
          </div>
          <p className="disclaimer">{data.mia.disclaimer}</p>
        </section>
      )}

      {activeSection === 'My Profile' && (
        <section className="screen-grid profile-screen">
          <ScreenHeading
            eyebrow="My Profile"
            title={data.profile.household.name}
            copy={data.profile.household.primary_goal}
          />

          <article className="panel completeness-card">
            <div>
              <span>Profile completeness</span>
              <strong>{data.profile.completeness}%</strong>
            </div>
            <div className="progress-track"><span style={{ width: `${data.profile.completeness}%` }} /></div>
            <p>{isRealWorkspace ? 'These are your saved household numbers. Update them anytime and Mia will use the new context.' : 'Manual entry works in the real workspace. Uploads are shown as the next natural path so users do not feel trapped in Excel.'}</p>
          </article>

          {isRealWorkspace && setupDraft && (
            <WorkspaceSetupForm
              formRef={setupFormRef}
              values={setupDraft}
              editing={isProfileEditing}
              saving={setupSaving}
              error={setupError}
              onBeginEdit={() => setIsProfileEditing(true)}
              onCancel={cancelProfileEditing}
              onChange={updateSetupDraft}
              onSubmit={handleSetupSubmit}
            />
          )}

          <DocumentImportWorkspace
            sectionRef={documentImportsRef}
            isRealWorkspace={Boolean(isRealWorkspace)}
            imports={documentImports}
            categories={activeBudgetPlan?.rows ?? []}
            selectedImport={selectedImport}
            loading={documentsLoading}
            error={documentsError}
            notice={documentsNotice}
            uploadingKind={uploadingKind}
            itemSavingIds={itemSavingIds}
            action={documentAction}
            draftAction={budgetAction}
            expandedAppliedImportId={expandedAppliedImportId}
            onExpandedAppliedImportIdChange={setExpandedAppliedImportId}
            demoUploads={data.profile.uploads}
            onUpload={handleDocumentUpload}
            onSelectImport={setSelectedImportId}
            onUpdateItem={handleDocumentItemUpdate}
            onUpdateDraft={handleUpdateTransactionDraft}
            onMatchDraft={handleMatchTransactionDraft}
            onConfirmDraft={handleConfirmTransactionDraft}
            onIgnoreDraft={handleIgnoreTransactionDraft}
            onReopenDraft={handleReopenTransactionDraft}
            onApply={handleApplyDocumentImport}
            onReprocess={handleReprocessDocumentImport}
            onDeleteSource={handleDeleteDocumentSource}
            onDeleteImport={handleDeleteDocumentImport}
            onOpenSource={handleOpenDocumentSource}
          />

          <div className="profile-section-grid">
            {data.profile.sections.map((section) => (
              <article className="panel profile-section" key={section.label}>
                <div className="row-between">
                  <h3>{section.label}</h3>
                  <button type="button" onClick={() => handleProfileSectionEdit(section.label)}>Edit</button>
                </div>
                <p>{section.summary}</p>
                {section.items.map((item) => (
                  <div className="money-row" key={item.label}>
                    <span>{item.label}</span>
                    <strong className={item.amount < 0 ? 'negative' : ''}>{currency.format(item.amount)}</strong>
                  </div>
                ))}
              </article>
            ))}
          </div>
        </section>
      )}

      {activeSection === 'Budget' && (
        <section className="screen-grid budget-screen">
          <ScreenHeading
            eyebrow="Budget"
            title="Build the annual plan, then keep the monthly truth current."
            copy={data.budget.intro}
          />

          <div className="metric-row">
            <Metric label="Monthly income" value={currency.format(data.budget.monthly_income)} />
            <Metric label="Monthly outflow" value={currency.format(data.budget.total_monthly_outflow)} />
            <Metric label="Baseline surplus" value={currency.format(data.budget.baseline_surplus)} />
          </div>

          <div className="stack-grid">
            {data.budget.stacks.map((stack) => (
              <article className={`stack-card ${stack.color}`} key={stack.label}>
                <span>{data.budget.framework}</span>
                <h3>{stack.label}</h3>
                <strong>{currency.format(stack.amount)}</strong>
                <p>{stack.description}</p>
                <small>{stack.examples.join(' · ')}</small>
              </article>
            ))}
          </div>

          {data.budget.annual_plan ? (
            <AnnualBudgetPlanner
              plan={data.budget.annual_plan}
              isRealWorkspace={Boolean(isRealWorkspace)}
              action={budgetAction}
              error={budgetError}
              selectedMonthIndex={selectedBudgetMonthIndex}
              spendingReport={spendingReport}
              spendingReportLoading={spendingReportLoading}
              spendingReportError={spendingReportError}
              newCategory={newBudgetCategory}
              onNewCategoryChange={setNewBudgetCategory}
              onCreateCategory={handleCreateBudgetCategory}
              onBudgetViewChange={handleBudgetViewChange}
              onSaveBudgetEdits={handleBudgetEditSave}
              onArchiveCategory={handleArchiveBudgetCategory}
              onRestoreCategory={handleRestoreBudgetCategory}
              onApplyMiaActionDraft={handleApplyMiaActionDraft}
              onCancelMiaActionDraft={handleCancelMiaActionDraft}
              onUpdateDraft={handleUpdateTransactionDraft}
              onMatchDraft={handleMatchTransactionDraft}
              onConfirmDraft={handleConfirmTransactionDraft}
              onIgnoreDraft={handleIgnoreTransactionDraft}
              onReopenDraft={handleReopenTransactionDraft}
            />
          ) : (
            <article className="panel coach-panel">
              <h3>Annual budget foundation</h3>
              <p>Sign in to a real workspace to plan each month, create custom categories, and confirm transactions from Mia chat.</p>
            </article>
          )}

          <article className="panel coach-panel">
            <h3>Custom categories matter</h3>
            <p>{data.budget.custom_categories_note}</p>
          </article>
        </section>
      )}

      {activeSection === 'Wealth' && (
        <section className="screen-grid wealth-screen">
          <ScreenHeading
            eyebrow="Wealth"
            title="Wealth means more options and less panic."
            copy={data.wealth.guidance}
          />

          <div className="metric-row">
            <Metric label="Net worth" value={currency.format(data.wealth.summary.net_worth)} />
            <Metric label="Liquid net worth" value={currency.format(data.wealth.summary.liquid_net_worth)} />
            <Metric label="Retirement projection" value={currency.format(data.wealth.summary.retirement_projection)} />
            <Metric label="Monthly wealth building" value={currency.format(data.wealth.summary.monthly_wealth_building)} />
          </div>

          <div className="milestone-list">
            {data.wealth.milestones.map((milestone) => (
              <article className={`milestone-card ${milestone.status}`} key={milestone.label}>
                <h3>{milestone.label}</h3>
                <div className="progress-track">
                  <span style={{ width: milestoneProgressWidth(milestone.current, milestone.target) }} />
                </div>
                <p>{milestone.current.toLocaleString()} / {milestone.target.toLocaleString()} {milestone.unit}</p>
              </article>
            ))}
          </div>
        </section>
      )}

      {activeSection === 'CFO Filter' && (
        <section className="screen-grid cfo-screen">
          <ScreenHeading
            eyebrow="CFO Filter"
            title="Should this money move happen now?"
            copy={data.cfoFilter.prompt}
          />

          <div className="decision-list">
            {data.cfoFilter.decisions.map((decision) => (
              <article className={`decision-card ${decision.recommendation.toLowerCase()}`} key={decision.item}>
                <div>
                  <span>{decision.recommendation}</span>
                  <h3>{decision.item}</h3>
                </div>
                <strong>{currency.format(decision.amount)}</strong>
                <p>{decision.reason}</p>
              </article>
            ))}
          </div>

          <article className="panel priority-card">
            <h3>Priority stack</h3>
            <ol>
              {data.cfoFilter.priority_stack.map((item) => <li key={item}>{item}</li>)}
            </ol>
          </article>
        </section>
      )}

      {activeSection === 'Optionality' && (
        <section className="screen-grid optionality-screen">
          <ScreenHeading
            eyebrow="Optionality"
            title={data.optionality.question}
            copy={`Current runway: ${data.optionality.current_runway_months} months. Target runway: ${data.optionality.target_runway_months} months.`}
          />

          <div className="lever-row">
            {data.optionality.levers.map((lever) => (
              <Metric key={lever.label} label={lever.label} value={currency.format(lever.amount)} />
            ))}
          </div>

          <div className="choice-grid">
            {data.optionality.choices.map((choice) => (
              <article className="choice-card" key={choice.label}>
                <span>{choice.readiness_score}/100 readiness</span>
                <h3>{choice.label}</h3>
                <p>{choice.upside}</p>
                <small>{choice.tradeoff}</small>
              </article>
            ))}
          </div>
        </section>
      )}

      {activeSection === ADMIN_SECTION && auth.currentUser?.is_admin && (
        <AdminConsole currentUser={auth.currentUser} />
      )}

      {confirmClearChat && (
        <ClearChatConfirmDialog
          isClearing={miaClearing}
          onCancel={() => setConfirmClearChat(false)}
          onConfirm={() => void handleClearMessages()}
        />
      )}

      {previewImport && (
        <DocumentSourcePreview
          key={previewImport.id}
          documentImport={previewImport}
          onClose={() => setPreviewImport(null)}
          onFetchSourceUrl={fetchDocumentImportSourceUrl}
          onFetchSourcePreview={fetchDocumentImportSourcePreview}
        />
      )}

      {previewAttachment && (
        <LocalAttachmentPreview attachment={previewAttachment} onClose={() => setPreviewAttachment(null)} />
      )}
    </main>
  )
}

function PendingAttachmentTray({
  attachments,
  onPreview,
  onRemove,
}: {
  attachments: PendingMiaAttachment[]
  onPreview: (attachment: PendingMiaAttachment) => void
  onRemove: (id: string) => void
}) {
  return (
    <div className="composer-attachment-tray" aria-label="Attachments waiting to send">
      {attachments.map((attachment) => (
        <div className="composer-attachment-card" key={attachment.id}>
          <button type="button" className="attachment-preview-button" onClick={() => onPreview(attachment)}>
            {browserPreviewableImage(attachment.content_type) ? <img src={attachment.previewUrl} alt={attachmentDisplayName(attachment)} /> : <AttachmentIcon />}
            <span>{attachmentDisplayName(attachment)}</span>
          </button>
          <button type="button" className="attachment-remove-button" aria-label={`Remove ${attachmentDisplayName(attachment)}`} onClick={() => onRemove(attachment.id)}>
            <CloseIcon />
          </button>
        </div>
      ))}
    </div>
  )
}

function MessageAttachmentList({
  attachments,
  imports,
  onOpenLocal,
  onOpenImport,
  onOpenImportId,
}: {
  attachments: MiaMessageAttachment[]
  imports: FinancialDocumentImport[]
  onOpenLocal: (attachment: MiaMessageAttachment) => void
  onOpenImport: (documentImport: FinancialDocumentImport) => void
  onOpenImportId: (documentImportId: number) => void
}) {
  return (
    <div className="message-attachment-list" aria-label="Message attachments">
      {attachments.map((attachment) => {
        const documentImport = attachment.document_import_id ? imports.find((candidate) => candidate.id === attachment.document_import_id) : null
        const hasImagePreview = Boolean(attachment.preview_url && browserPreviewableImage(attachment.content_type))
        const canOpen = Boolean(attachment.document_import_id || attachment.preview_url || documentImport?.source_available)
        return (
          <button
            type="button"
            className={`message-attachment-card ${hasImagePreview ? 'is-image' : ''}`}
            key={`${attachment.document_import_id ?? attachment.filename}-${attachment.filename}`}
            disabled={!canOpen}
            aria-label={`Open ${messageAttachmentDisplayName(attachment)}`}
            onClick={() => {
              if (documentImport) onOpenImport(documentImport)
              else if (attachment.document_import_id) onOpenImportId(attachment.document_import_id)
              else if (attachment.preview_url) onOpenLocal(attachment)
            }}
          >
            {hasImagePreview ? <img src={attachment.preview_url} alt={messageAttachmentDisplayName(attachment)} /> : <AttachmentIcon />}
            {!hasImagePreview && <span>{messageAttachmentDisplayName(attachment)}</span>}
          </button>
        )
      })}
    </div>
  )
}

function LocalAttachmentPreview({ attachment, onClose }: { attachment: PendingMiaAttachment; onClose: () => void }) {
  const isImage = browserPreviewableImage(attachment.content_type)

  return (
    <div className="document-preview-overlay" role="presentation">
      <button type="button" className="document-preview-backdrop" aria-label="Close attachment preview" onClick={onClose} />
      <section className="local-attachment-preview" role="dialog" aria-modal="true" aria-label={attachmentDisplayName(attachment)}>
        <div className="document-preview-header">
          <div>
            <span className="document-status blue">Attachment preview</span>
            <strong>{attachmentDisplayName(attachment)}</strong>
          </div>
          <button type="button" className="document-preview-close-button" onClick={onClose}>Close</button>
        </div>
        <div className="document-preview-body">
          {isImage ? <img src={attachment.previewUrl} alt={attachmentDisplayName(attachment)} /> : <div className="document-preview-state"><AttachmentIcon /><p>Preview will be available after upload.</p></div>}
        </div>
      </section>
    </div>
  )
}

function ClearChatConfirmDialog({
  isClearing,
  onCancel,
  onConfirm,
}: {
  isClearing: boolean
  onCancel: () => void
  onConfirm: () => void
}) {
  return (
    <div className="clear-chat-overlay" role="presentation">
      <button type="button" className="clear-chat-backdrop" aria-label="Keep Mia chat" onClick={onCancel} />
      <section className="clear-chat-dialog" role="dialog" aria-modal="true" aria-labelledby="clear-chat-title" aria-describedby="clear-chat-copy">
        <p className="eyebrow">Ask Mia</p>
        <h3 id="clear-chat-title">Clear this chat?</h3>
        <p id="clear-chat-copy">
          This removes the messages in this conversation and Mia will not be able to pick up this thread later.
          Your saved budget, profile, and transactions stay unchanged.
        </p>
        <div className="clear-chat-dialog-actions">
          <button type="button" className="secondary" onClick={onCancel} disabled={isClearing} autoFocus>
            Keep chat
          </button>
          <button type="button" className="danger" onClick={onConfirm} disabled={isClearing}>
            {isClearing ? 'Clearing' : 'Clear chat'}
          </button>
        </div>
      </section>
    </div>
  )
}

function AuthLanding() {
  return (
    <main className="app loading-state auth-state">
      <section className="hero-panel auth-panel">
        <span className="spark" aria-hidden="true"><ShieldIcon /></span>
        <p className="eyebrow">Secure cohort access</p>
        <h1>Sign in to open your Household CFO Method workspace.</h1>
        <p>
          Household CFO Method now uses Clerk authentication backed by the Rails/PostgreSQL user table.
          Sign in with the email invited to the first cohort.
        </p>
        <div className="auth-actions">
          <SignInButton mode="modal">
            <button type="button">Sign in</button>
          </SignInButton>
          <SignUpButton mode="modal">
            <button type="button" className="secondary">Create invited account</button>
          </SignUpButton>
        </div>
      </section>
    </main>
  )
}

function AccessDenied({ message, onSignOut }: { message: string; onSignOut?: () => Promise<void> }) {
  return (
    <main className="app loading-state auth-state">
      <section className="hero-panel auth-panel">
        <span className="spark" aria-hidden="true"><ShieldIcon /></span>
        <p className="eyebrow">Access needs an invitation</p>
        <h1>Your Clerk session is active, but this app has not linked your cohort seat.</h1>
        <p>{message}</p>
        <div className="auth-actions">
          <button type="button" onClick={() => void onSignOut?.()}>Sign out</button>
          <div className="user-button-wrap"><UserButton afterSignOutUrl="/" /></div>
        </div>
      </section>
    </main>
  )
}

function AuthStatePanel({ title, copy }: { title: string; copy: string }) {
  return (
    <main className="app loading-state auth-state">
      <section className="hero-panel auth-panel">
        <span className="spark" aria-hidden="true"><MiaMark /></span>
        <p className="eyebrow">Household CFO Method powered by VERA</p>
        <h1>{title}</h1>
        <p>{copy}</p>
      </section>
    </main>
  )
}

function ScreenHeading({ eyebrow, title, copy }: { eyebrow: string; title: string; copy: string }) {
  return (
    <div className="screen-heading">
      <p className="eyebrow">{eyebrow}</p>
      <h2>{title}</h2>
      <p>{copy}</p>
    </div>
  )
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <article className="metric-card">
      <span>{label}</span>
      <strong>{value}</strong>
    </article>
  )
}

function milestoneProgressWidth(current: number, target: number) {
  if (target <= 0) return current > 0 ? '100%' : '0%'

  return `${Math.min((current / target) * 100, 100)}%`
}

function DocumentContextCard({
  imports,
  pendingCount,
  processingCount,
  onOpenProfile,
  onAttach,
  uploading,
}: {
  imports: FinancialDocumentImport[]
  pendingCount: number
  processingCount: number
  onOpenProfile: () => void
  onAttach: () => void
  uploading: boolean
}) {
  const latestApplied = latestAppliedImport(imports)

  return (
    <div className="document-context-card">
      <div className="document-context-stats" aria-label="Document import context for Mia">
        <span><strong>{pendingCount}</strong> waiting review</span>
        <span><strong>{processingCount}</strong> processing</span>
      </div>
      <p>
        {latestApplied
          ? `Latest approved source: ${documentKindLabel(latestApplied.document_kind)} · ${importPeriodLabel(latestApplied)}.`
          : 'No approved document sources yet. Mia will use manual numbers until you apply extracted values.'}
      </p>
      <div className="upload-strip">
        <button type="button" onClick={onAttach} disabled={uploading}>
          <AttachmentIcon />
          {uploading ? 'Uploading privately' : 'Attach document'}
        </button>
        <button type="button" onClick={onOpenProfile}>
          <StatementIcon />
          Review imports
        </button>
      </div>
    </div>
  )
}

function DocumentImportWorkspace({
  sectionRef,
  isRealWorkspace,
  imports,
  categories,
  selectedImport,
  loading,
  error,
  notice,
  uploadingKind,
  itemSavingIds,
  action,
  draftAction,
  expandedAppliedImportId,
  onExpandedAppliedImportIdChange,
  demoUploads,
  onUpload,
  onSelectImport,
  onUpdateItem,
  onUpdateDraft,
  onMatchDraft,
  onConfirmDraft,
  onIgnoreDraft,
  onReopenDraft,
  onApply,
  onReprocess,
  onDeleteSource,
  onDeleteImport,
  onOpenSource,
}: {
  sectionRef?: Ref<HTMLElement>
  isRealWorkspace: boolean
  imports: FinancialDocumentImport[]
  categories: BudgetCategoryRow[]
  selectedImport: FinancialDocumentImport | null
  loading: boolean
  error: string | null
  notice: string | null
  uploadingKind: DocumentImportKind | null
  itemSavingIds: Set<number>
  action: string | null
  draftAction: string | null
  expandedAppliedImportId: number | null
  onExpandedAppliedImportIdChange: (id: number | null) => void
  demoUploads: Array<{ label: string; kind: string; status: string; accepts: string }>
  onUpload: (kind: DocumentImportKind, file: File, origin?: 'profile' | 'mia') => void
  onSelectImport: (id: number) => void
  onUpdateItem: (documentImportId: number, itemId: number, values: DocumentImportItemInput) => Promise<void> | void
  onUpdateDraft: (draft: TransactionDraft, values: TransactionDraftUpdateInput) => Promise<void> | void
  onMatchDraft: (draft: TransactionDraft, matchId?: number) => void
  onConfirmDraft: (draft: TransactionDraft) => void
  onIgnoreDraft: (draft: TransactionDraft) => void
  onReopenDraft: (draft: TransactionDraft) => void
  onApply: (documentImport: FinancialDocumentImport) => void
  onReprocess: (documentImport: FinancialDocumentImport) => void
  onDeleteSource: (documentImport: FinancialDocumentImport) => void
  onDeleteImport: (documentImport: FinancialDocumentImport) => void
  onOpenSource: (documentImport: FinancialDocumentImport) => void
}) {
  const pendingCount = imports.filter((documentImport) => documentImport.status === 'needs_review').length
  const latestApplied = latestAppliedImport(imports)

  if (!isRealWorkspace) {
    return (
      <section ref={sectionRef} className="panel document-import-workspace demo-document-imports" aria-label="Document uploads preview">
        <div className="document-workspace-heading">
          <div>
            <p className="eyebrow">Private document import</p>
            <h3>Upload review is enabled in signed-in real workspaces.</h3>
            <p>Demo mode keeps uploads disabled so no private files land in sample data.</p>
          </div>
          <span className="document-safe-pill">Private S3 only</span>
        </div>
        <div className="upload-grid">
          {demoUploads.map((upload) => (
            <article className="upload-card" key={upload.kind}>
              <span>Upload</span>
              <h3>{upload.label}</h3>
              <p>{upload.status}</p>
              <small>{upload.accepts}</small>
            </article>
          ))}
        </div>
      </section>
    )
  }

  return (
    <section ref={sectionRef} className="panel document-import-workspace" aria-label="Private financial document imports">
      <div className="document-workspace-heading">
        <div>
          <p className="eyebrow">Private document import</p>
          <h3>Upload evidence. Review draft facts. Apply only what is right.</h3>
          <p>Files go to private S3. Mia extracts draft values server-side, then waits for your approval before changing household numbers.</p>
        </div>
        <span className="document-safe-pill">Private S3 · Review first</span>
      </div>

      <div className="document-import-summary-row">
        <Metric label="Needs review" value={String(pendingCount)} />
        <Metric label="Total imports" value={String(imports.length)} />
        <Metric label="Latest source" value={latestApplied ? documentKindLabel(latestApplied.document_kind) : 'None yet'} />
        <Metric label="Freshness" value={latestApplied ? importPeriodLabel(latestApplied) : 'Manual'} />
      </div>

      <div className="document-import-guide">
        <div>
          <strong>Not sure what to upload?</strong>
          <p>Start with our Excel budget template, or bring your own Excel, CSV, PDF, Word document, statement, pay stub, or receipt. Mia drafts values only after upload.</p>
        </div>
        <a href="/household-cfo-budget-template.xlsx" download>Download Excel template</a>
      </div>

      {error && <p className="document-alert error" role="alert">{error}</p>}
      {notice && <p className="document-alert success" role="status">{notice}</p>}

      <div className="document-upload-grid">
        {documentUploadCards.map((card) => (
          <DocumentUploadCard
            key={card.kind}
            card={card}
            uploading={uploadingKind === card.kind}
            disabled={Boolean(uploadingKind)}
            onUpload={(file) => onUpload(card.kind, file, 'profile')}
          />
        ))}
      </div>

      <div className="document-review-layout">
        <DocumentImportHistory
          imports={imports}
          selectedImportId={selectedImport?.id ?? null}
          loading={loading}
          onSelectImport={onSelectImport}
        />
        <DocumentReviewPanel
          documentImport={selectedImport}
          categories={categories}
          itemSavingIds={itemSavingIds}
          action={action}
          draftAction={draftAction}
          appliedDetailsOpen={Boolean(selectedImport && selectedImport.status === 'applied' && selectedImport.id === expandedAppliedImportId)}
          onAppliedDetailsOpenChange={(open) => onExpandedAppliedImportIdChange(open && selectedImport ? selectedImport.id : null)}
          onUpdateItem={onUpdateItem}
          onUpdateDraft={onUpdateDraft}
          onMatchDraft={onMatchDraft}
          onConfirmDraft={onConfirmDraft}
          onIgnoreDraft={onIgnoreDraft}
          onReopenDraft={onReopenDraft}
          onApply={onApply}
          onReprocess={onReprocess}
          onDeleteSource={onDeleteSource}
          onDeleteImport={onDeleteImport}
          onOpenSource={onOpenSource}
          onUpload={onUpload}
          uploading={Boolean(uploadingKind)}
        />
      </div>
    </section>
  )
}

function DocumentUploadCard({
  card,
  uploading,
  disabled,
  onUpload,
}: {
  card: (typeof documentUploadCards)[number]
  uploading: boolean
  disabled: boolean
  onUpload: (file: File) => void
}) {
  const inputId = `document-upload-${card.kind}`

  return (
    <article className="document-upload-card">
      <input
        id={inputId}
        className="sr-only"
        type="file"
        accept={card.accepts}
        disabled={disabled}
        onChange={(event) => {
          const file = event.target.files?.[0]
          if (file) onUpload(file)
          event.currentTarget.value = ''
        }}
      />
      <label htmlFor={inputId} aria-disabled={disabled}>
        <span>{card.eyebrow}</span>
        <h4>{card.label}</h4>
        <p>{card.helper}</p>
        <small>{card.accepts.replaceAll(',', ' · ')}</small>
        <strong>{uploading ? 'Uploading privately' : 'Choose file'}</strong>
      </label>
    </article>
  )
}

type DocumentHistoryStatusFilter = 'all' | FinancialDocumentImport['status']
type DocumentHistoryKindFilter = 'all' | DocumentImportKind
type DocumentHistorySort = 'newest' | 'oldest' | 'needs_review'

function DocumentImportHistory({
  imports,
  selectedImportId,
  loading,
  onSelectImport,
}: {
  imports: FinancialDocumentImport[]
  selectedImportId: number | null
  loading: boolean
  onSelectImport: (id: number) => void
}) {
  const [search, setSearch] = useState('')
  const [statusFilter, setStatusFilter] = useState<DocumentHistoryStatusFilter>('all')
  const [kindFilter, setKindFilter] = useState<DocumentHistoryKindFilter>('all')
  const [sort, setSort] = useState<DocumentHistorySort>('newest')
  const [page, setPage] = useState(0)
  const pageSize = 6
  const filteredImports = useMemo(() => {
    const query = search.trim().toLowerCase()
    return imports
      .filter((documentImport) => statusFilter === 'all' || documentImport.status === statusFilter)
      .filter((documentImport) => kindFilter === 'all' || documentImport.document_kind === kindFilter)
      .filter((documentImport) => {
        if (!query) return true
        return [
          documentImportDisplayName(documentImport),
          documentImport.filename,
          documentImport.extracted_summary ?? '',
          documentImport.items.map((item) => `${item.label} ${item.evidence ?? ''} ${item.amount ?? ''} ${item.balance ?? ''} ${item.payment ?? ''}`).join(' '),
          documentImport.transaction_drafts.map((draft) => `${draft.merchant} ${draft.summary ?? ''}`).join(' '),
          documentKindLabel(documentImport.document_kind),
          importStatusLabel(documentImport.status),
          importPeriodLabel(documentImport),
        ].join(' ').toLowerCase().includes(query)
      })
      .sort((left, right) => {
        if (sort === 'oldest') return importTimestamp(left) - importTimestamp(right) || left.id - right.id
        if (sort === 'needs_review') {
          const leftRank = left.status === 'needs_review' ? 0 : PROCESSING_IMPORT_STATUSES.has(left.status) ? 1 : 2
          const rightRank = right.status === 'needs_review' ? 0 : PROCESSING_IMPORT_STATUSES.has(right.status) ? 1 : 2
          return leftRank - rightRank || importTimestamp(right) - importTimestamp(left) || right.id - left.id
        }
        return importTimestamp(right) - importTimestamp(left) || right.id - left.id
      })
  }, [imports, kindFilter, search, sort, statusFilter])
  const totalPages = Math.max(1, Math.ceil(filteredImports.length / pageSize))
  const safePage = Math.min(page, totalPages - 1)
  const visibleImports = filteredImports.slice(safePage * pageSize, safePage * pageSize + pageSize)

  return (
    <aside className="document-history" aria-label="Document import history">
      <div className="document-history-heading">
        <h4>Import history</h4>
        <span>{loading ? 'Refreshing' : `${imports.length} total`}</span>
      </div>
      {imports.length > 0 && (
        <div className="document-history-controls" aria-label="Import history filters">
          <label className="document-history-search">
            <span className="sr-only">Search imports</span>
            <input value={search} placeholder="Search imports" onChange={(event) => { setSearch(event.currentTarget.value); setPage(0) }} />
          </label>
          <label>
            <span className="sr-only">Filter by status</span>
            <select value={statusFilter} onChange={(event) => { setStatusFilter(event.currentTarget.value as DocumentHistoryStatusFilter); setPage(0) }}>
              <option value="all">All statuses</option>
              <option value="needs_review">Needs review</option>
              <option value="processing">Processing</option>
              <option value="uploaded">Uploaded</option>
              <option value="applied">Applied</option>
              <option value="partially_applied">Partially applied</option>
              <option value="failed">Failed</option>
              <option value="source_deleted">Source deleted</option>
            </select>
          </label>
          <label>
            <span className="sr-only">Filter by type</span>
            <select value={kindFilter} onChange={(event) => { setKindFilter(event.currentTarget.value as DocumentHistoryKindFilter); setPage(0) }}>
              <option value="all">All types</option>
              <option value="receipt">Receipts</option>
              <option value="statement">Statements</option>
              <option value="spreadsheet">Spreadsheets</option>
              <option value="pay_stub">Pay stubs</option>
              <option value="other">Other</option>
            </select>
          </label>
          <label>
            <span className="sr-only">Sort imports</span>
            <select value={sort} onChange={(event) => { setSort(event.currentTarget.value as DocumentHistorySort); setPage(0) }}>
              <option value="newest">Newest first</option>
              <option value="oldest">Oldest first</option>
              <option value="needs_review">Review first</option>
            </select>
          </label>
        </div>
      )}
      {imports.length === 0 ? (
        <div className="document-empty-state">
          <StatementIcon />
          <h4>No documents yet</h4>
          <p>Upload a sample-safe document to test extraction. Avoid real client statements in local demos.</p>
        </div>
      ) : visibleImports.length === 0 ? (
        <div className="document-empty-state compact">
          <h4>No imports match</h4>
          <p>Clear the search or change filters to see more uploads.</p>
        </div>
      ) : (
        <>
          <div className="document-history-list">
            {visibleImports.map((documentImport) => (
              <button
                type="button"
                key={documentImport.id}
                className={`document-history-card ${selectedImportId === documentImport.id ? 'active' : ''}`}
                onClick={() => onSelectImport(documentImport.id)}
              >
                <span className={`document-status ${importStatusTone(documentImport.status)}`}>{importStatusLabel(documentImport.status)}</span>
                <strong>{documentImportDisplayName(documentImport)}</strong>
                <small>{documentKindLabel(documentImport.document_kind)} · {formatByteSize(documentImport.byte_size)}</small>
                <small>{importPeriodLabel(documentImport)}</small>
              </button>
            ))}
          </div>
          <div className="document-history-pagination" aria-label="Import history pagination">
            <span>{filteredImports.length === 0 ? '0 shown' : `${safePage * pageSize + 1}-${Math.min((safePage + 1) * pageSize, filteredImports.length)} of ${filteredImports.length}`}</span>
            <div>
              <button type="button" disabled={safePage === 0} onClick={() => setPage((current) => Math.max(current - 1, 0))}>Previous</button>
              <button type="button" disabled={safePage >= totalPages - 1} onClick={() => setPage((current) => Math.min(current + 1, totalPages - 1))}>Next</button>
            </div>
          </div>
        </>
      )}
    </aside>
  )
}

function DocumentReviewPanel({
  documentImport,
  categories,
  itemSavingIds,
  action,
  draftAction,
  appliedDetailsOpen,
  onAppliedDetailsOpenChange,
  onUpdateItem,
  onUpdateDraft,
  onMatchDraft,
  onConfirmDraft,
  onIgnoreDraft,
  onReopenDraft,
  onApply,
  onReprocess,
  onDeleteSource,
  onDeleteImport,
  onOpenSource,
  onUpload,
  uploading,
}: {
  documentImport: FinancialDocumentImport | null
  categories: BudgetCategoryRow[]
  itemSavingIds: Set<number>
  action: string | null
  draftAction: string | null
  appliedDetailsOpen: boolean
  onAppliedDetailsOpenChange: (open: boolean) => void
  onUpdateItem: (documentImportId: number, itemId: number, values: DocumentImportItemInput) => Promise<void> | void
  onUpdateDraft: (draft: TransactionDraft, values: TransactionDraftUpdateInput) => Promise<void> | void
  onMatchDraft: (draft: TransactionDraft, matchId?: number) => void
  onConfirmDraft: (draft: TransactionDraft) => void
  onIgnoreDraft: (draft: TransactionDraft) => void
  onReopenDraft: (draft: TransactionDraft) => void
  onApply: (documentImport: FinancialDocumentImport) => void
  onReprocess: (documentImport: FinancialDocumentImport) => void
  onDeleteSource: (documentImport: FinancialDocumentImport) => void
  onDeleteImport: (documentImport: FinancialDocumentImport) => void
  onOpenSource: (documentImport: FinancialDocumentImport) => void
  onUpload: (kind: DocumentImportKind, file: File, origin?: 'profile' | 'mia') => void
  uploading: boolean
}) {
  if (!documentImport) {
    const inputId = 'document-empty-upload'

    return (
      <article className="document-review-panel document-empty-state">
        <AttachmentIcon />
        <h4>Upload a document to begin</h4>
        <p>Choose one of the upload cards above, or start here with a budget, statement, PDF, Excel file, Word doc, pay stub, or receipt. Mia will never apply extracted numbers until you approve them.</p>
        <input
          id={inputId}
          className="sr-only"
          type="file"
          accept={SUPPORTED_DOCUMENT_ACCEPTS}
          disabled={uploading}
          onChange={(event) => {
            const file = event.target.files?.[0]
            if (file) onUpload(inferDocumentKind(file), file, 'profile')
            event.currentTarget.value = ''
          }}
        />
        <label className="document-empty-upload-button" htmlFor={inputId} aria-disabled={uploading}>{uploading ? 'Uploading privately' : 'Choose a document'}</label>
      </article>
    )
  }

  if (!documentImport.details_included) {
    return (
      <article className="document-review-panel document-empty-state" aria-label={`Loading ${documentImportDisplayName(documentImport)}`}>
        <AttachmentIcon />
        <h4>Loading review details</h4>
        <p>Mia is opening the extracted values, transaction drafts, split lines, and matches for {documentImportDisplayName(documentImport)}.</p>
      </article>
    )
  }

  const warnings = metadataWarnings(documentImport)
  const groupedItems = groupedImportItems(documentImport.items)
  const selectedCount = selectedApplyItemIds(documentImport).length
  const reviewable = REVIEWABLE_IMPORT_STATUSES.has(documentImport.status)
  const processing = PROCESSING_IMPORT_STATUSES.has(documentImport.status)
  const fullyApplied = documentImport.status === 'applied'
  const actionForImport = (name: string) => action === `${name}:${documentImport.id}`

  return (
    <article className="document-review-panel" aria-label={`Review ${documentImportDisplayName(documentImport)}`}>
      <div className="document-review-header">
        <div>
          <span className={`document-status ${importStatusTone(documentImport.status)}`}>{importStatusLabel(documentImport.status)}</span>
          <h4>{documentImportDisplayName(documentImport)}</h4>
          <p>{documentKindLabel(documentImport.document_kind)} · {formatByteSize(documentImport.byte_size)} · {importPeriodLabel(documentImport)}</p>
        </div>
        <div className="document-review-actions">
          <button type="button" onClick={() => onOpenSource(documentImport)} disabled={!documentImport.source_available || actionForImport('source-url')}>
            {actionForImport('source-url') ? 'Opening' : 'Preview source'}
          </button>
          {fullyApplied ? (
            <>
              <span className="document-action-hint">Upload a new copy to reprocess</span>
              <button type="button" className="subtle" onClick={() => onAppliedDetailsOpenChange(!appliedDetailsOpen)}>
                {appliedDetailsOpen ? 'Hide saved values' : 'Edit saved values'}
              </button>
            </>
          ) : (
            <button type="button" onClick={() => onReprocess(documentImport)} disabled={!documentImport.source_available || processing || documentImport.status === 'partially_applied' || actionForImport('reprocess')}>
              {actionForImport('reprocess') ? 'Starting' : 'Reprocess'}
            </button>
          )}
          <button type="button" className="subtle" onClick={() => onDeleteSource(documentImport)} disabled={!documentImport.source_available || actionForImport('source')}>
            {actionForImport('source') ? 'Deleting' : 'Delete source'}
          </button>
          <button type="button" className="danger" onClick={() => onDeleteImport(documentImport)} disabled={documentImport.items.some((item) => item.applied_at) || actionForImport('delete')}>
            {actionForImport('delete') ? 'Deleting' : 'Delete import'}
          </button>
        </div>
      </div>

      <div className="document-summary-box">
        <strong>Mia read</strong>
        <p>{documentImport.extracted_summary || statusExplainer(documentImport)}</p>
        {(documentImport.metadata.extraction_page_count || documentImport.metadata.transaction_draft_count) && (
          <div className="document-extraction-coverage" aria-label="Statement extraction coverage">
            {documentImport.metadata.extraction_page_count && <span>{documentImport.metadata.extraction_page_count} PDF pages processed</span>}
            {documentImport.metadata.extraction_batch_count && <span>{documentImport.metadata.extraction_batch_count} extraction batches completed</span>}
            {typeof documentImport.metadata.transaction_draft_count === 'number' && <span>{documentImport.metadata.transaction_draft_count} transaction reviews created</span>}
          </div>
        )}
        {documentImport.extraction_error && <p className="document-error-copy">{documentImport.extraction_error}</p>}
      </div>

      {warnings.length > 0 && (
        <div className="document-warning-list" role="note" aria-label="Extraction warnings">
          {warnings.map((warning) => <span key={warning}>{warning}</span>)}
        </div>
      )}

      {processing && (
        <div className="document-processing-state" role="status">
          <span />
          <p>Mia is extracting draft values and transaction rows. This panel refreshes automatically.</p>
        </div>
      )}

      {(documentImport.transaction_drafts ?? []).length > 0 && (
        <section className="document-transaction-drafts" aria-label="Extracted transaction drafts">
          <div className="document-item-group-heading">
            <h5>Transaction drafts</h5>
            <span>{(documentImport.transaction_drafts ?? []).length} proposed row{(documentImport.transaction_drafts ?? []).length === 1 ? '' : 's'}</span>
          </div>
          <TransactionDraftReviewStack
            drafts={documentImport.transaction_drafts ?? []}
            isRealWorkspace
            action={draftAction}
            compact
            categories={categories}
            onUpdate={onUpdateDraft}
            onMatch={onMatchDraft}
            onConfirm={onConfirmDraft}
            onIgnore={onIgnoreDraft}
            onReopen={onReopenDraft}
          />
        </section>
      )}

      {fullyApplied && !appliedDetailsOpen && documentImport.items.some((item) => item.applied_at) && (
        <AppliedImportSummary documentImport={documentImport} onEdit={() => onAppliedDetailsOpenChange(true)} />
      )}

      {documentImport.items.length > 0 && (!fullyApplied || appliedDetailsOpen) && (
        <div className="document-items-shell">
          {groupedItems.map(([targetType, items]) => (
            <section className="document-item-group" key={targetType}>
              <div className="document-item-group-heading">
                <h5>{targetTypeLabel(targetType)}</h5>
                <span>{items.length} draft value{items.length === 1 ? '' : 's'}</span>
              </div>
              <div className="document-item-list">
                {items.map((item) => (
                  <DocumentImportItemEditor
                    key={documentItemSignature(item)}
                    documentImport={documentImport}
                    item={item}
                    saving={itemSavingIds.has(item.id)}
                    onUpdate={(values) => onUpdateItem(documentImport.id, item.id, values)}
                  />
                ))}
              </div>
            </section>
          ))}
        </div>
      )}

      <div className={`document-apply-bar ${fullyApplied ? 'applied' : ''}`}>
        <div>
          <strong>{fullyApplied ? 'Saved household numbers' : `${selectedCount} selected`}</strong>
          <span>{fullyApplied ? (appliedDetailsOpen ? 'Correcting a saved value updates Mia and the dashboard immediately.' : 'This source is already applied. Expand only when you need to correct source-backed details.') : reviewable ? 'Approve only values you recognize.' : 'This import is not currently reviewable.'}</span>
        </div>
        {fullyApplied ? (
          <button type="button" onClick={() => onAppliedDetailsOpenChange(!appliedDetailsOpen)}>
            {appliedDetailsOpen ? 'Collapse details' : 'Edit saved values'}
          </button>
        ) : (
          <button type="button" onClick={() => onApply(documentImport)} disabled={!reviewable || selectedCount === 0 || actionForImport('apply')}>
            {actionForImport('apply') ? 'Applying' : 'Apply selected'}
          </button>
        )}
      </div>
    </article>
  )
}

function AppliedImportSummary({ documentImport, onEdit }: { documentImport: FinancialDocumentImport; onEdit: () => void }) {
  const appliedItems = documentImport.items.filter((item) => item.applied_at)
  const groups = groupedImportItems(appliedItems)
  const groupSummary = groups.map(([targetType, items]) => ({
    label: targetTypeLabel(targetType),
    count: items.length,
    total: items.reduce((sum, item) => sum + appliedItemDisplayValue(item), 0),
  }))

  return (
    <div className="document-applied-summary">
      <div className="document-applied-summary-copy">
        <span className="document-status green">Applied household budget</span>
        <h5>{appliedItems.length} saved value{appliedItems.length === 1 ? '' : 's'} already feed Mia</h5>
        <p>The detailed correction cards are tucked away so the profile stays scannable. Open them only when a source-backed number needs a correction.</p>
      </div>
      <div className="document-applied-summary-grid" aria-label="Applied import value groups">
        {groupSummary.map((group) => (
          <article key={group.label}>
            <span>{group.label}</span>
            <strong>{group.count}</strong>
            <small>{currency.format(group.total)}</small>
          </article>
        ))}
      </div>
      <button type="button" onClick={onEdit}>Edit saved values</button>
    </div>
  )
}

function appliedItemDisplayValue(item: DocumentImportItem) {
  if (item.target_type === 'debt') return item.balance ? -item.balance : 0
  return item.balance ?? item.amount ?? item.payment ?? 0
}

function DocumentSourcePreview({
  documentImport,
  onClose,
  onFetchSourceUrl,
  onFetchSourcePreview,
}: {
  documentImport: FinancialDocumentImport
  onClose: () => void
  onFetchSourceUrl: (id: number) => Promise<DocumentSourceUrl>
  onFetchSourcePreview: (id: number) => Promise<DocumentSourcePreviewData>
}) {
  const [source, setSource] = useState<DocumentSourceUrl | null>(null)
  const [preview, setPreview] = useState<DocumentSourcePreviewData | null>(null)
  const [loading, setLoading] = useState(true)
  const [previewLoading, setPreviewLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [previewError, setPreviewError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false

    onFetchSourceUrl(documentImport.id)
      .then((payload) => {
        if (cancelled) return

        setSource(payload)
        if (!usesServerPreview(payload.filename, payload.content_type)) return

        setPreviewLoading(true)
        onFetchSourcePreview(documentImport.id)
          .then((previewPayload) => {
            if (!cancelled) setPreview(previewPayload)
          })
          .catch((caught) => {
            if (!cancelled) setPreviewError(caught instanceof Error ? caught.message : 'Secure document preview could not be loaded.')
          })
          .finally(() => {
            if (!cancelled) setPreviewLoading(false)
          })
      })
      .catch((caught) => {
        if (!cancelled) setError(caught instanceof Error ? caught.message : 'Secure document preview could not be loaded.')
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })

    return () => {
      cancelled = true
    }
  }, [documentImport.id, onFetchSourcePreview, onFetchSourceUrl])

  useEffect(() => {
    const handleKeyDown = (event: globalThis.KeyboardEvent) => {
      if (event.key === 'Escape') onClose()
    }

    document.addEventListener('keydown', handleKeyDown)
    document.body.style.overflow = 'hidden'
    return () => {
      document.removeEventListener('keydown', handleKeyDown)
      document.body.style.overflow = ''
    }
  }, [onClose])

  const filename = source?.filename ?? documentImport.filename
  const previewTitle = documentImportDisplayName(documentImport)
  const contentType = source?.content_type ?? documentImport.content_type
  const isImage = source?.inline_supported === true && browserPreviewableImage(contentType)
  const isPdf = source?.inline_supported === true && contentType === 'application/pdf'
  const serverPreviewType = usesServerPreview(filename, contentType)

  return (
    <div className="document-preview-overlay" role="presentation">
      <button type="button" className="document-preview-backdrop" aria-label="Close document preview" onClick={onClose} />
      <section className="document-preview-modal" role="dialog" aria-modal="true" aria-label={`Preview ${previewTitle}`}>
        <header className="document-preview-header">
          <div>
            <span className="document-status blue">Private preview</span>
            <h3>{previewTitle}</h3>
            <p>{documentKindLabel(documentImport.document_kind)} · {formatByteSize(documentImport.byte_size)} · Private source saved; preview links refresh when opened.</p>
          </div>
          <div className="document-preview-actions">
            {source && <a href={source.download_url} target="_blank" rel="noopener noreferrer">Download source</a>}
            <button type="button" onClick={onClose}>Close</button>
          </div>
        </header>

        <div className="document-preview-body">
          {loading && <div className="document-preview-state"><span className="document-preview-spinner" />Loading private document preview…</div>}
          {error && <div className="document-preview-state error">{error}</div>}

          {source && !loading && !error && (
            <>
              {isPdf && <iframe src={`${source.url}#toolbar=1&navpanes=0`} title={filename} />}
              {isImage && <img src={source.url} alt={filename} />}
              {serverPreviewType && previewLoading && <div className="document-preview-state"><span className="document-preview-spinner" />Building safe in-app preview…</div>}
              {serverPreviewType && previewError && <div className="document-preview-state error">{previewError}</div>}
              {preview?.type === 'spreadsheet' && <SpreadsheetSourcePreview preview={preview} />}
              {preview?.type === 'text' && <TextSourcePreview preview={preview} />}
              {!isPdf && !isImage && !serverPreviewType && (
                <div className="document-preview-state">
                  <StatementIcon />
                  <h4>Preview not available for this file type</h4>
                  <p>Use “Download source” to save the secure source file.</p>
                </div>
              )}
            </>
          )}
        </div>
      </section>
    </div>
  )
}

function SpreadsheetSourcePreview({ preview }: { preview: DocumentSourcePreviewData }) {
  const sheets = preview.sheets ?? []

  if (sheets.length === 0) {
    return (
      <div className="document-preview-state">
        <StatementIcon />
        <h4>No rows to preview</h4>
        <p>The document is readable, but no populated spreadsheet rows were found.</p>
      </div>
    )
  }

  return (
    <div className="document-spreadsheet-preview">
      {sheets.map((sheet) => (
        <section className="document-preview-sheet" key={sheet.name}>
          <div className="document-preview-sheet-heading">
            <strong>{sheet.name}</strong>
            <span>{sheet.sampled_row_count} of {sheet.row_count} rows shown</span>
          </div>
          <div className="document-preview-table-wrap">
            <table>
              <tbody>
                {sheet.rows.map((row) => (
                  <tr key={row.row}>
                    <th scope="row">{row.row}</th>
                    {row.values.map((value, index) => (
                      <td key={`${row.row}-${index}`}>{value}</td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      ))}
    </div>
  )
}

function TextSourcePreview({ preview }: { preview: DocumentSourcePreviewData }) {
  return (
    <div className="document-text-preview">
      <pre>{preview.text || 'No text could be shown for this document.'}</pre>
    </div>
  )
}

function usesServerPreview(filename: string, contentType: string) {
  const name = filename.toLowerCase()
  return name.endsWith('.csv') || name.endsWith('.xls') || name.endsWith('.xlsx') || name.endsWith('.docx') || [
    'text/csv',
    'text/plain',
    'application/csv',
    'application/vnd.ms-excel',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  ].includes(contentType)
}

type EditableDocumentItemDraft = {
  target_type: DocumentImportItem['target_type']
  label: string
  amount: string
  balance: string
  payment: string
  cadence: string
  source_type: string
  stack_key: string
  account_type: string
  debt_type: string
  evidence: string
}

function DocumentImportItemEditor({
  documentImport,
  item,
  saving,
  onUpdate,
}: {
  documentImport: FinancialDocumentImport
  item: DocumentImportItem
  saving: boolean
  onUpdate: (values: DocumentImportItemInput) => Promise<void> | void
}) {
  const applied = Boolean(item.applied_at)
  const canEditDraft = !applied && REVIEWABLE_IMPORT_STATUSES.has(documentImport.status)
  const canCorrectApplied = applied && documentImport.status !== 'source_deleted'
  const editable = canEditDraft || canCorrectApplied
  const selectionDisabled = saving || applied || !canEditDraft
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState<EditableDocumentItemDraft>(() => editableDocumentItemDraft(item))
  const moneyFields = documentItemMoneyFields(draft.target_type)
  const fieldsDisabled = saving || !editing
  const targetDisabled = saving || !editing || applied || !canEditDraft

  function updateDraft(values: Partial<EditableDocumentItemDraft>) {
    setDraft((current) => ({ ...current, ...values }))
  }

  function beginEditing() {
    setDraft(editableDocumentItemDraft(item))
    setEditing(true)
  }

  function cancelEditing() {
    setDraft(editableDocumentItemDraft(item))
    setEditing(false)
  }

  async function saveEdits() {
    await onUpdate(documentItemUpdatePayload(draft))
    setEditing(false)
  }

  return (
    <article className={`document-item-card ${item.ignored ? 'ignored' : ''} ${item.applied_at ? 'applied' : ''} ${editing ? 'editing' : ''}`}>
      <div className="document-item-topline">
        <label className="document-check">
          <input
            type="checkbox"
            checked={item.selected && !item.ignored}
            disabled={selectionDisabled || editing}
            onChange={(event) => onUpdate({ selected: event.target.checked, ignored: false })}
          />
          <span>{item.applied_at ? 'Applied' : 'Apply'}</span>
        </label>
        <button
          type="button"
          className="document-ignore-button"
          disabled={selectionDisabled || editing}
          onClick={() => onUpdate({ ignored: !item.ignored, selected: item.ignored })}
        >
          {item.ignored ? 'Restore' : 'Ignore'}
        </button>
        {saving && <span className="document-saving">Saving</span>}
        {applied && canCorrectApplied && !editing && <span className="document-saving applied-editable">Saved number</span>}
        {item.confidence && <span className={`confidence-pill ${item.confidence}`}>{item.confidence} confidence</span>}
        {editable && (
          <div className="document-item-edit-actions">
            {editing ? (
              <>
                <button type="button" className="secondary-button" disabled={saving} onClick={cancelEditing}>Cancel</button>
                <button type="button" disabled={saving || draft.label.trim().length === 0} onClick={() => void saveEdits()}>{saving ? 'Saving' : 'Save'}</button>
              </>
            ) : (
              <button type="button" className="secondary-button" disabled={saving} onClick={beginEditing}>{applied ? 'Correct value' : 'Edit value'}</button>
            )}
          </div>
        )}
      </div>

      <div className="document-item-fields">
        <label className="document-field wide">
          <span>Label</span>
          <input
            value={draft.label}
            disabled={fieldsDisabled}
            onChange={(event) => updateDraft({ label: event.currentTarget.value })}
          />
        </label>
        <label className="document-field">
          <span>Target</span>
          <select value={draft.target_type} disabled={targetDisabled} onChange={(event) => updateDraft({ target_type: event.currentTarget.value as DocumentImportItem['target_type'] })}>
            {targetTypeOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
          </select>
        </label>
        {moneyFields.map((field) => (
          <label className="document-field" key={field.key}>
            <span>{field.label}</span>
            <input
              type="number"
              min="0"
              step="0.01"
              value={draft[field.key]}
              disabled={fieldsDisabled}
              onChange={(event) => updateDraft({ [field.key]: event.currentTarget.value })}
            />
          </label>
        ))}
        {(draft.target_type === 'income_source' || draft.target_type === 'expense_item') && (
          <label className="document-field">
            <span>Cadence</span>
            <select value={draft.cadence} disabled={fieldsDisabled} onChange={(event) => updateDraft({ cadence: event.currentTarget.value })}>
              {cadenceOptions.map((option) => <option key={option} value={option}>{titleize(option)}</option>)}
            </select>
          </label>
        )}
        {draft.target_type === 'income_source' && (
          <label className="document-field">
            <span>Income type</span>
            <select value={draft.source_type} disabled={fieldsDisabled} onChange={(event) => updateDraft({ source_type: event.currentTarget.value })}>
              {sourceTypeOptions.map((option) => <option key={option} value={option}>{titleize(option)}</option>)}
            </select>
          </label>
        )}
        {draft.target_type === 'expense_item' && (
          <label className="document-field">
            <span>Stack</span>
            <select value={draft.stack_key} disabled={fieldsDisabled} onChange={(event) => updateDraft({ stack_key: event.currentTarget.value })}>
              {stackKeyOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
            </select>
          </label>
        )}
        {draft.target_type === 'account' && (
          <label className="document-field">
            <span>Account type</span>
            <select value={draft.account_type} disabled={fieldsDisabled} onChange={(event) => updateDraft({ account_type: event.currentTarget.value })}>
              {accountTypeOptions.map((option) => <option key={option} value={option}>{titleize(option)}</option>)}
            </select>
          </label>
        )}
        {draft.target_type === 'debt' && (
          <label className="document-field">
            <span>Debt type</span>
            <select value={draft.debt_type} disabled={fieldsDisabled} onChange={(event) => updateDraft({ debt_type: event.currentTarget.value })}>
              {debtTypeOptions.map((option) => <option key={option} value={option}>{titleize(option)}</option>)}
            </select>
          </label>
        )}
      </div>

      {item.evidence && <p className="document-evidence">{item.evidence}</p>}
      {applied && canCorrectApplied && (
        <p className="document-evidence applied-note">
          Click Correct value before changing saved household numbers. Nothing updates until you press Save.
        </p>
      )}
      {!applied && canEditDraft && <p className="document-evidence applied-note">Draft fields are locked until you click Edit value, then Save.</p>}
    </article>
  )
}

const targetTypeOptions: Array<{ value: DocumentImportItem['target_type']; label: string }> = [
  { value: 'income_source', label: 'Income' },
  { value: 'expense_item', label: 'Expense' },
  { value: 'account', label: 'Account' },
  { value: 'debt', label: 'Debt' },
  { value: 'goal', label: 'Goal' },
  { value: 'profile_note', label: 'Profile note' },
]

const cadenceOptions = ['weekly', 'biweekly', 'semi_monthly', 'monthly', 'annual', 'one_time']
const sourceTypeOptions = ['job', 'business', 'rental', 'passive', 'bonus', 'other']
const accountTypeOptions = ['checking', 'savings', 'emergency_fund', 'retirement', 'investment', 'property', 'other']
const debtTypeOptions = ['credit_card', 'student_loan', 'auto_loan', 'mortgage', 'personal_loan', 'medical', 'other']
const stackKeyOptions = [
  { value: 'non_discretionary', label: 'Non-discretionary' },
  { value: 'discretionary', label: 'Discretionary' },
  { value: 'sinking_expected', label: 'Sinking Fund — Expected' },
  { value: 'sinking_unexpected', label: 'Sinking Fund — Unexpected' },
]

function attachmentDisplayName(attachment: PendingMiaAttachment) {
  if (attachment.document_kind === 'receipt' && attachment.content_type.startsWith('image/')) return 'Receipt screenshot'
  if (attachment.document_kind === 'statement' && attachment.content_type.startsWith('image/')) return 'Statement screenshot'
  if (attachment.content_type.startsWith('image/')) return 'Screenshot'

  return documentKindLabel(attachment.document_kind)
}

function messageAttachmentDisplayName(attachment: MiaMessageAttachment) {
  if (attachment.document_kind === 'receipt' && attachment.content_type.startsWith('image/')) return 'Receipt screenshot'
  if (attachment.document_kind === 'statement' && attachment.content_type.startsWith('image/')) return 'Statement screenshot'
  if (attachment.content_type.startsWith('image/')) return 'Screenshot'

  return documentKindLabel(attachment.document_kind)
}

function documentImportDisplayName(documentImport: FinancialDocumentImport) {
  if (documentImport.document_kind === 'receipt' && documentImport.content_type.startsWith('image/') && generatedEvidenceFilename(documentImport.filename)) {
    return 'Receipt screenshot'
  }
  if (documentImport.document_kind === 'statement' && documentImport.content_type.startsWith('image/') && generatedEvidenceFilename(documentImport.filename)) {
    return 'Statement screenshot'
  }
  if (documentImport.content_type.startsWith('image/') && generatedEvidenceFilename(documentImport.filename)) return 'Screenshot upload'

  return documentImport.filename
}

function generatedEvidenceFilename(filename: string) {
  return /^(?:pasted[-_]evidence|receipt[-_]screenshot|screenshot[-_]upload|mia[-_]attachment)/i.test(filename)
}

function documentKindLabel(kind: DocumentImportKind) {
  const labels: Record<DocumentImportKind, string> = {
    spreadsheet: 'Spreadsheet',
    statement: 'Statement',
    pay_stub: 'Pay stub',
    receipt: 'Receipt/photo',
    other: 'Document',
  }

  return labels[kind]
}

class MiaAttachmentError extends Error {
  attachments: PendingMiaAttachment[]

  constructor(message: string, attachments: PendingMiaAttachment[], options?: ErrorOptions) {
    super(message, options)
    this.attachments = attachments
  }
}

class MiaAttachmentUploadError extends MiaAttachmentError {
  constructor(message: string, attachments: PendingMiaAttachment[], options?: ErrorOptions) {
    super(message, attachments, options)
    this.name = 'MiaAttachmentUploadError'
  }
}

function attachmentWithDocumentImport(attachment: PendingMiaAttachment, documentImport: FinancialDocumentImport): PendingMiaAttachment {
  return {
    ...attachment,
    document_import_id: documentImport.id,
    status: documentImport.status,
    source_available: documentImport.source_available,
  }
}

function attachmentWithMessageContext(attachment: PendingMiaAttachment, message: string): PendingMiaAttachment {
  const documentKind = documentKindForMessageContext(attachment.file, attachment.document_kind, message)
  return documentKind === attachment.document_kind ? attachment : { ...attachment, document_kind: documentKind }
}

function documentKindForMessageContext(file: File, currentKind: DocumentImportKind, message: string): DocumentImportKind {
  if (!budgetSetupSignal(`${file.name} ${message}`)) return currentKind
  if (currentKind === 'spreadsheet' || currentKind === 'pay_stub') return currentKind
  return 'other'
}

function budgetSetupSignal(text: string) {
  const normalized = text.toLowerCase().replace(/[^a-z0-9&]+/g, ' ')
  return /\b(my|our|household|monthly|annual|family)\s+budget\b|\bbudget\s+(file|spreadsheet|sheet|screenshot|plan|setup|template|worksheet)\b|\b(set\s*up|update|build)\s+(my|our|the)?\s*budget\b|\bexpense\s+stack\b|\bincome\s+(and|&)\s+expenses\b/i.test(normalized)
}

function pendingMiaAttachment(file: File): PendingMiaAttachment {
  const contentType = normalizedContentType(file)
  return {
    id: clientSideId('attachment'),
    file,
    filename: file.name || `receipt-screenshot-${timestampForFilename()}.jpg`,
    content_type: contentType,
    document_kind: inferDocumentKind(file),
    previewUrl: URL.createObjectURL(file),
  }
}

function localAttachmentForMessage(attachment: PendingMiaAttachment): MiaMessageAttachment {
  return {
    document_import_id: attachment.document_import_id,
    filename: attachment.filename,
    content_type: attachment.content_type,
    document_kind: attachment.document_kind,
    status: attachment.status ?? 'uploaded',
    source_available: attachment.source_available ?? false,
    preview_url: attachment.previewUrl,
  }
}

function attachLocalPreviewsToMessage(message: MiaMessage, attachments: PendingMiaAttachment[]): MiaMessage {
  if (!message.attachments || attachments.length === 0) return message

  return {
    ...message,
    attachments: message.attachments.map((attachment, index) => ({
      ...attachment,
      preview_url: attachments[index]?.previewUrl,
    })),
  }
}

function filesFromClipboard(data: DataTransfer) {
  const files = Array.from(data.files ?? [])
  if (files.length > 0) return files.map(normalizedEvidenceFile)

  return Array.from(data.items ?? [])
    .filter((item) => item.kind === 'file')
    .map((item) => item.getAsFile())
    .filter((file): file is File => Boolean(file))
    .map(normalizedEvidenceFile)
}

function normalizedEvidenceFile(file: File, index: number) {
  const existingName = file.name.trim()
  const extension = extensionForFile(file)
  const hasUsefulName = Boolean(existingName && fileExtension(existingName) && !/^image\.(?:png|jpe?g|webp|heic|heif)$/i.test(existingName))
  if (hasUsefulName) return file

  const fallbackExtension = extension ?? 'jpg'
  const prefix = normalizedContentType(file).startsWith('image/') ? 'receipt-screenshot' : 'mia-upload'
  return new File([file], `${prefix}-${timestampForFilename()}-${index + 1}.${fallbackExtension}`, {
    type: file.type || contentTypeForExtension(fallbackExtension) || 'application/octet-stream',
    lastModified: file.lastModified,
  })
}

function isSupportedEvidenceFile(file: File) {
  const extension = extensionForFile(file)
  const contentType = normalizedContentType(file)
  if (extension && SUPPORTED_EVIDENCE_EXTENSIONS.has(extension)) return true
  if (SUPPORTED_EVIDENCE_CONTENT_TYPES.has(contentType)) return true

  return false
}

function normalizedContentType(file: File) {
  return file.type.toLowerCase() || contentTypeForExtension(extensionForFile(file) ?? '') || 'application/octet-stream'
}

function fileExtension(filename: string) {
  const match = filename.toLowerCase().match(/\.([a-z0-9]+)$/)
  return match?.[1] ?? null
}

function extensionForFile(file: File) {
  return fileExtension(file.name) ?? extensionForContentType(file.type)
}

function browserPreviewableImage(contentType: string) {
  return ['image/jpeg', 'image/png', 'image/webp'].includes(contentType.toLowerCase())
}

function sleep(milliseconds: number) {
  return new Promise((resolve) => window.setTimeout(resolve, milliseconds))
}

function clientSideId(prefix: string) {
  const cryptoApi = globalThis.crypto
  if (typeof cryptoApi?.randomUUID === 'function') return `${prefix}-${cryptoApi.randomUUID()}`

  if (typeof cryptoApi?.getRandomValues === 'function') {
    const bytes = new Uint8Array(12)
    cryptoApi.getRandomValues(bytes)
    return `${prefix}-${Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('')}`
  }

  return `${prefix}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`
}

function timestampForFilename() {
  return new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, '')
}

function extensionForContentType(contentType: string) {
  const normalized = contentType.toLowerCase()
  if (normalized === 'image/jpeg') return 'jpg'
  if (normalized === 'image/png') return 'png'
  if (normalized === 'image/webp') return 'webp'
  if (normalized === 'image/heic') return 'heic'
  if (normalized === 'image/heif') return 'heif'
  if (normalized === 'application/pdf') return 'pdf'
  if (normalized === 'text/csv' || normalized === 'application/csv') return 'csv'
  if (normalized === 'application/vnd.ms-excel') return 'xls'
  if (normalized === 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet') return 'xlsx'
  if (normalized === 'application/vnd.openxmlformats-officedocument.wordprocessingml.document') return 'docx'

  return null
}

function contentTypeForExtension(extension: string) {
  const normalized = extension.toLowerCase().replace(/^\./, '')
  const map: Record<string, string> = {
    jpg: 'image/jpeg',
    jpeg: 'image/jpeg',
    png: 'image/png',
    webp: 'image/webp',
    heic: 'image/heic',
    heif: 'image/heif',
    pdf: 'application/pdf',
    csv: 'text/csv',
    xls: 'application/vnd.ms-excel',
    xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  }

  return map[normalized] ?? null
}

const SUPPORTED_EVIDENCE_EXTENSIONS = new Set(['pdf', 'csv', 'xls', 'xlsx', 'docx', 'jpg', 'jpeg', 'png', 'webp', 'heic', 'heif'])
const SUPPORTED_EVIDENCE_CONTENT_TYPES = new Set([
  'application/pdf',
  'text/csv',
  'application/csv',
  'application/vnd.ms-excel',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/heic',
  'image/heif',
])

function inferDocumentKind(file: File): DocumentImportKind {
  const name = file.name.toLowerCase()
  const contentType = file.type.toLowerCase()
  const isSpreadsheet = name.endsWith('.csv') || name.endsWith('.xls') || name.endsWith('.xlsx')
  const isWord = name.endsWith('.docx') || contentType === 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
  const isImage = name.endsWith('.jpg') || name.endsWith('.jpeg') || name.endsWith('.png') || name.endsWith('.webp') || name.endsWith('.heic') || name.endsWith('.heif') || contentType.startsWith('image/')
  const isPdf = name.endsWith('.pdf') || contentType === 'application/pdf'

  if (isSpreadsheet) return 'spreadsheet'
  if (hasPayStubSignal(name)) return 'pay_stub'
  if (budgetSetupSignal(name)) return 'other'
  if (isImage) return 'receipt'
  if (isPdf) return 'statement'
  if (isWord) return 'other'

  return 'other'
}

function hasPayStubSignal(name: string) {
  return /(^|[^a-z0-9])(pay[-_\s]?stub|pay[-_\s]?slip|payslip|earnings[-_\s]?statement|payroll)([^a-z0-9]|$)/.test(name)
}

function importStatusLabel(status: FinancialDocumentImport['status']) {
  return titleize(status)
}

function importStatusTone(status: FinancialDocumentImport['status']) {
  if (status === 'applied') return 'green'
  if (status === 'partially_applied' || status === 'needs_review') return 'gold'
  if (status === 'failed' || status === 'source_deleted') return 'red'

  return 'blue'
}

function formatByteSize(bytes: number) {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`

  return `${(bytes / 1024 / 1024).toFixed(1)} MB`
}

function formatOptionalDate(value: string | null) {
  if (!value) return null

  return new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', year: 'numeric' }).format(new Date(`${value}T00:00:00`))
}

function importPeriodLabel(documentImport: FinancialDocumentImport) {
  const start = formatOptionalDate(documentImport.period_start_on)
  const end = formatOptionalDate(documentImport.period_end_on)
  const documentDate = formatOptionalDate(documentImport.document_date)
  if (start && end) return `${start} – ${end}`
  if (end) return `Through ${end}`
  if (documentDate) return documentDate
  if (documentImport.applied_at) return `Applied ${shortDateTime(documentImport.applied_at)}`
  if (documentImport.processed_at) return `Processed ${shortDateTime(documentImport.processed_at)}`

  return 'Date pending'
}

function metadataWarnings(documentImport: FinancialDocumentImport) {
  return Array.isArray(documentImport.metadata.warnings)
    ? documentImport.metadata.warnings.filter((warning): warning is string => typeof warning === 'string' && warning.trim().length > 0).slice(0, 5)
    : []
}

function groupedImportItems(items: DocumentImportItem[]) {
  const groups = new Map<DocumentImportItem['target_type'], DocumentImportItem[]>()
  items.forEach((item) => {
    groups.set(item.target_type, [...(groups.get(item.target_type) ?? []), item])
  })

  return Array.from(groups.entries())
}

function targetTypeLabel(targetType: DocumentImportItem['target_type']) {
  return targetTypeOptions.find((option) => option.value === targetType)?.label ?? titleize(targetType)
}

function documentItemMoneyFields(targetType: DocumentImportItem['target_type']): Array<{ key: 'amount' | 'balance' | 'payment'; label: string }> {
  if (targetType === 'profile_note') return []
  if (targetType === 'account') return [{ key: 'balance', label: 'Balance' }]
  if (targetType === 'debt') {
    return [
      { key: 'balance', label: 'Balance' },
      { key: 'payment', label: 'Payment' },
    ]
  }

  return [{ key: 'amount', label: targetType === 'goal' ? 'Target amount' : 'Monthly amount' }]
}

function editableDocumentItemDraft(item: DocumentImportItem): EditableDocumentItemDraft {
  return {
    target_type: item.target_type,
    label: item.label,
    amount: moneyDraftValue(item.amount),
    balance: moneyDraftValue(item.balance),
    payment: moneyDraftValue(item.payment),
    cadence: item.cadence ?? 'monthly',
    source_type: item.source_type ?? 'other',
    stack_key: item.stack_key ?? 'discretionary',
    account_type: item.account_type ?? 'other',
    debt_type: item.debt_type ?? 'other',
    evidence: item.evidence ?? '',
  }
}

function moneyDraftValue(value: number | null) {
  return value === null ? '' : String(value)
}

function documentItemUpdatePayload(draft: EditableDocumentItemDraft): DocumentImportItemInput {
  const payload: DocumentImportItemInput = {
    target_type: draft.target_type,
    label: draft.label.trim(),
    evidence: draft.evidence,
  }

  if (draft.target_type === 'income_source') {
    return { ...payload, amount: draft.amount, cadence: draft.cadence, source_type: draft.source_type }
  }
  if (draft.target_type === 'expense_item') {
    return { ...payload, amount: draft.amount, cadence: draft.cadence, stack_key: draft.stack_key }
  }
  if (draft.target_type === 'account') {
    return { ...payload, balance: draft.balance, account_type: draft.account_type }
  }
  if (draft.target_type === 'debt') {
    return { ...payload, balance: draft.balance, payment: draft.payment, debt_type: draft.debt_type }
  }
  if (draft.target_type === 'goal') {
    return { ...payload, amount: draft.amount }
  }

  return payload
}

function documentItemSignature(item: DocumentImportItem) {
  return [
    item.id,
    item.target_type,
    item.label,
    item.amount,
    item.balance,
    item.payment,
    item.cadence,
    item.source_type,
    item.stack_key,
    item.account_type,
    item.debt_type,
    item.evidence,
    item.selected,
    item.ignored,
    item.applied_at,
  ].join('|')
}

function selectedApplyItemIds(documentImport: FinancialDocumentImport) {
  return documentImport.items
    .filter((item) => item.selected && !item.ignored && !item.applied_at)
    .map((item) => item.id)
}

function latestAppliedImport(imports: FinancialDocumentImport[]) {
  return imports
    .filter((documentImport) => documentImport.status === 'applied' || documentImport.status === 'partially_applied')
    .sort((left, right) => importTimestamp(right) - importTimestamp(left))[0] ?? null
}

function latestFullyAppliedImport(imports: FinancialDocumentImport[]) {
  return imports
    .filter((documentImport) => documentImport.status === 'applied')
    .sort((left, right) => importTimestamp(right) - importTimestamp(left))[0] ?? null
}

function importTimestamp(documentImport: FinancialDocumentImport) {
  const timestamp = Date.parse(documentImport.applied_at ?? documentImport.processed_at ?? '')
  return Number.isNaN(timestamp) ? 0 : timestamp
}

function mergeImportSummariesWithDetails(summaries: FinancialDocumentImport[], current: FinancialDocumentImport[]) {
  return summaries.map((summary) => {
    const existing = current.find((documentImport) => documentImport.id === summary.id)
    if (!existing?.details_included) return summary
    if (!importDetailsStillCurrent(summary, existing)) return summary

    return {
      ...summary,
      details_included: true,
      items: existing.items,
      transaction_drafts: existing.transaction_drafts,
      attempts: existing.attempts,
    }
  })
}

function importDetailsStillCurrent(summary: FinancialDocumentImport, existing: FinancialDocumentImport) {
  return summary.status === existing.status &&
    summary.processed_at === existing.processed_at &&
    summary.applied_at === existing.applied_at &&
    summary.source_deleted_at === existing.source_deleted_at &&
    summary.updated_at === existing.updated_at
}

function replaceImport(imports: FinancialDocumentImport[], documentImport: FinancialDocumentImport) {
  const exists = imports.some((existing) => existing.id === documentImport.id)
  const nextImports = exists
    ? imports.map((existing) => (existing.id === documentImport.id ? documentImport : existing))
    : [documentImport, ...imports]

  return nextImports.sort((left, right) => right.id - left.id)
}

function replaceImportItem(imports: FinancialDocumentImport[], documentImportId: number, item: DocumentImportItem) {
  return imports.map((documentImport) => {
    if (documentImport.id !== documentImportId) return documentImport

    return {
      ...documentImport,
      items: documentImport.items.map((existing) => (existing.id === item.id ? item : existing)),
    }
  })
}

function statusExplainer(documentImport: FinancialDocumentImport) {
  if (documentImport.status === 'uploaded' || documentImport.status === 'processing') return 'Extraction is in progress. Draft values will appear here when Mia finishes reading the source.'
  if (documentImport.status === 'failed') return 'Mia could not extract reliable draft values from this upload. You can delete it or reprocess if the source is still available.'
  if (documentImport.status === 'source_deleted') return 'The private source file has been deleted. Existing extracted metadata remains for audit context.'
  if (documentImport.status === 'applied') return 'All selected values from this document were approved and applied to the household workspace.'
  if (documentImport.status === 'partially_applied') return 'Some values were applied. Unapplied values remain available for review.'

  return 'Review each draft value before applying it to your official household numbers.'
}

function setupFocusFieldForSection(sectionLabel: string): keyof WorkspaceSetupValues {
  const normalized = sectionLabel.toLowerCase()
  if (normalized.includes('income')) return 'primary_income'
  if (normalized.includes('expense')) return 'fixed_expenses'
  if (normalized.includes('debt')) return 'credit_card_debt'
  if (normalized.includes('saving')) return 'emergency_fund'

  return 'household_name'
}

type AdminUserDraft = {
  role: UserRole
  invitation_status: InvitationStatus
  cohort_ids: string[]
}

type UserStatusFilter = 'active' | 'all' | InvitationStatus
type UserRoleFilter = 'all' | UserRole
type UserSortKey = 'name_asc' | 'email_asc' | 'role_asc' | 'status_asc' | 'setup_desc' | 'invite_desc'

const cohortStatuses: AdminCohortStatus[] = ['draft', 'enrolling', 'active', 'completed', 'archived']
const userRoles: UserRole[] = ['participant', 'coach', 'admin']
const invitationStatuses: InvitationStatus[] = ['pending', 'accepted', 'revoked']

function AdminConsole({ currentUser }: { currentUser: CurrentUser }) {
  const [cohorts, setCohorts] = useState<AdminCohort[]>([])
  const [users, setUsers] = useState<AdminUser[]>([])
  const [selectedCohortId, setSelectedCohortId] = useState<number | null>(null)
  const [createDraft, setCreateDraft] = useState<AdminCohortInput>({
    name: '',
    status: 'enrolling',
    starts_on: '',
    ends_on: '',
    notes: '',
  })
  const [editDraft, setEditDraft] = useState<AdminCohortInput | null>(null)
  const [inviteDraft, setInviteDraft] = useState<AdminUserInput>({
    email: '',
    first_name: '',
    last_name: '',
    role: 'participant',
    cohort_id: '',
    send_invitation_email: true,
  })
  const [userDrafts, setUserDrafts] = useState<Record<number, AdminUserDraft>>({})
  const [userSearch, setUserSearch] = useState('')
  const [userStatusFilter, setUserStatusFilter] = useState<UserStatusFilter>('active')
  const [userRoleFilter, setUserRoleFilter] = useState<UserRoleFilter>('all')
  const [userSort, setUserSort] = useState<UserSortKey>('name_asc')
  const [loading, setLoading] = useState(true)
  const [cohortSaving, setCohortSaving] = useState(false)
  const [inviteSaving, setInviteSaving] = useState(false)
  const [savingUserIds, setSavingUserIds] = useState<Set<number>>(() => new Set())
  const [resendingUserIds, setResendingUserIds] = useState<Set<number>>(() => new Set())
  const [roleMatrixOpen, setRoleMatrixOpen] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const selectedCohortIdRef = useRef<number | null | undefined>(undefined)

  const displayCohorts = useMemo(() => cohorts.map((cohort) => cohortWithUserStats(cohort, users)), [cohorts, users])

  const selectedCohort = useMemo(
    () => displayCohorts.find((cohort) => cohort.id === selectedCohortId) ?? null,
    [displayCohorts, selectedCohortId],
  )

  const scopedUsers = useMemo(() => {
    if (!selectedCohortId) return users

    return users.filter((user) => user.cohorts.some((membership) => membership.cohort.id === selectedCohortId))
  }, [selectedCohortId, users])

  const visibleUsers = useMemo(
    () => filterAndSortAdminUsers(scopedUsers, {
      search: userSearch,
      status: userStatusFilter,
      role: userRoleFilter,
      sort: userSort,
    }),
    [scopedUsers, userRoleFilter, userSearch, userSort, userStatusFilter],
  )

  const activeScopedUserCount = useMemo(() => scopedUsers.filter((user) => user.invitation_status !== 'revoked').length, [scopedUsers])

  const adminStats = useMemo(() => ({
    cohorts: cohorts.length,
    users: users.length,
    pending: users.filter((user) => user.invitation_status === 'pending').length,
    setupComplete: users.filter((user) => user.workspace.setup_complete).length,
  }), [cohorts.length, users])

  const loadAdminData = useCallback(async (preferredCohortId?: number | null) => {
    setLoading(true)
    setError(null)
    try {
      const [nextCohorts, nextUsers] = await Promise.all([fetchAdminCohorts(), fetchAdminUsers()])
      const requestedCohortId = preferredCohortId === undefined ? selectedCohortIdRef.current : preferredCohortId
      const nextSelectedId = requestedCohortId === null
        ? null
        : requestedCohortId && nextCohorts.some((cohort) => cohort.id === requestedCohortId)
          ? requestedCohortId
          : nextCohorts[0]?.id ?? null
      const nextSelectedCohort = nextCohorts.find((cohort) => cohort.id === nextSelectedId) ?? null

      selectedCohortIdRef.current = nextSelectedId
      setCohorts(nextCohorts)
      setUsers(nextUsers)
      setUserDrafts(adminDraftsForUsers(nextUsers))
      setSelectedCohortId(nextSelectedId)
      setEditDraft(nextSelectedCohort ? cohortDraftFor(nextSelectedCohort) : null)
      setInviteDraft((current) => ({
        ...current,
        cohort_id: current.cohort_id || (nextSelectedId ? String(nextSelectedId) : ''),
      }))
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Admin data could not be loaded.')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    let cancelled = false

    queueMicrotask(() => {
      if (!cancelled) void loadAdminData()
    })

    return () => {
      cancelled = true
    }
  }, [loadAdminData])

  function selectCohort(cohortId: number | null) {
    selectedCohortIdRef.current = cohortId
    setSelectedCohortId(cohortId)
    setEditDraft(cohortId ? cohortDraftFor(cohorts.find((cohort) => cohort.id === cohortId) ?? null) : null)
    setNotice(null)
    setInviteDraft((current) => ({ ...current, cohort_id: cohortId ? String(cohortId) : '' }))
  }

  async function handleCreateCohort(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!createDraft.name.trim()) {
      setError('Cohort name is required.')
      return
    }

    setCohortSaving(true)
    setError(null)
    setNotice(null)
    try {
      const cohort = await createAdminCohort(cleanCohortDraft(createDraft))
      setNotice(`${cohort.name} is ready for invites.`)
      setCreateDraft({ name: '', status: 'enrolling', starts_on: '', ends_on: '', notes: '' })
      await loadAdminData(cohort.id)
      setInviteDraft((current) => ({ ...current, cohort_id: String(cohort.id) }))
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Cohort could not be created.')
    } finally {
      setCohortSaving(false)
    }
  }

  async function handleUpdateCohort(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!selectedCohort || !editDraft) return

    setCohortSaving(true)
    setError(null)
    setNotice(null)
    try {
      const cohort = await updateAdminCohort(selectedCohort.id, cleanCohortDraft(editDraft))
      setNotice(`${cohort.name} settings saved.`)
      await loadAdminData(cohort.id)
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Cohort could not be saved.')
    } finally {
      setCohortSaving(false)
    }
  }

  async function handleInviteUser(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const inviteRole = inviteDraft.role ?? 'participant'
    const cohortId = String(inviteDraft.cohort_id ?? '')

    if (!inviteDraft.email?.trim()) {
      setError('Email is required before creating an invite.')
      return
    }
    if (roleRequiresCohort(inviteRole) && !cohortId) {
      setError(`${titleize(inviteRole)} users must be assigned to at least one cohort.`)
      return
    }

    setInviteSaving(true)
    setError(null)
    setNotice(null)
    try {
      const response = await createAdminUser({
        email: inviteDraft.email.trim(),
        first_name: inviteDraft.first_name?.trim(),
        last_name: inviteDraft.last_name?.trim(),
        role: inviteRole,
        cohort_id: cohortId || undefined,
        send_invitation_email: inviteDraft.send_invitation_email ?? true,
      })
      setNotice(`${response.user.email} ${inviteActionNotice(response)}${cohortId ? ' and assigned to the selected cohort' : ' as an admin'}. ${inviteDeliveryNotice(response)}`)
      setInviteDraft({ email: '', first_name: '', last_name: '', role: 'participant', cohort_id: selectedCohortId ? String(selectedCohortId) : '', send_invitation_email: true })
      await loadAdminData()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Invite could not be created.')
    } finally {
      setInviteSaving(false)
    }
  }

  async function handleSaveUser(user: AdminUser) {
    const draft = userDrafts[user.id]
    if (!draft || savingUserIds.has(user.id)) return
    if (cohortRequiredFor(draft.role, draft.invitation_status) && draft.cohort_ids.length === 0) {
      setError(`${titleize(draft.role)} users must be assigned to at least one cohort before saving unless access is revoked.`)
      return
    }

    markUserSaving(user.id, true)
    setError(null)
    setNotice(null)
    try {
      const updatedUser = await updateAdminUser(user.id, {
        role: draft.role,
        invitation_status: draft.invitation_status,
        cohort_ids: draft.cohort_ids.map(Number),
      })
      setNotice(`${updatedUser.email} was updated.`)
      await loadAdminData()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'User could not be saved.')
    } finally {
      markUserSaving(user.id, false)
    }
  }

  async function handleResendInvitation(user: AdminUser) {
    if (resendingUserIds.has(user.id)) return

    markUserResending(user.id, true)
    setError(null)
    setNotice(null)
    try {
      const response = await resendAdminUserInvitation(user.id)
      setNotice(`${response.user.email} invitation refreshed. ${inviteDeliveryNotice(response)}`)
      await loadAdminData()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Invitation email could not be resent.')
    } finally {
      markUserResending(user.id, false)
    }
  }

  async function handleCancelInvite(user: AdminUser) {
    if (savingUserIds.has(user.id)) return

    markUserSaving(user.id, true)
    setError(null)
    setNotice(null)
    try {
      const updatedUser = await updateAdminUser(user.id, {
        invitation_status: 'revoked',
        cohort_ids: [],
      })
      setNotice(`${updatedUser.email} invite was cancelled and removed from cohorts.`)
      await loadAdminData()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Invite could not be cancelled.')
    } finally {
      markUserSaving(user.id, false)
    }
  }

  async function handleRemoveFromSelectedCohort(user: AdminUser) {
    if (!selectedCohortId || savingUserIds.has(user.id)) return
    const selectedId = String(selectedCohortId)
    const nextCohortIds = serverCohortIdsForUser(user).filter((cohortId) => cohortId !== selectedId)
    const shouldRevokeAfterRemoval = cohortRequiredFor(user.role, user.invitation_status) && nextCohortIds.length === 0
    const mutation: AdminUserInput = { cohort_ids: nextCohortIds.map(Number) }
    if (shouldRevokeAfterRemoval) mutation.invitation_status = 'revoked'

    markUserSaving(user.id, true)
    setError(null)
    setNotice(null)
    try {
      const updatedUser = await updateAdminUser(user.id, mutation)
      const cohortName = selectedCohort?.name ?? 'this cohort'
      setNotice(shouldRevokeAfterRemoval
        ? `${updatedUser.email} was removed from ${cohortName} and access was revoked because no cohorts remain.`
        : `${updatedUser.email} was removed from ${cohortName}.`)
      await loadAdminData(selectedCohortId)
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'User could not be removed from this cohort.')
    } finally {
      markUserSaving(user.id, false)
    }
  }

  function markUserSaving(userId: number, saving: boolean) {
    setSavingUserIds((current) => toggleIdInSet(current, userId, saving))
  }

  function markUserResending(userId: number, resending: boolean) {
    setResendingUserIds((current) => toggleIdInSet(current, userId, resending))
  }

  function updateUserDraft(userId: number, key: 'role' | 'invitation_status', value: string) {
    setUserDrafts((current) => {
      const nextDraft = { ...current[userId] }
      if (key === 'role') nextDraft.role = value as UserRole
      if (key === 'invitation_status') nextDraft.invitation_status = value as InvitationStatus

      return {
        ...current,
        [userId]: nextDraft,
      }
    })
  }

  function toggleUserCohort(userId: number, cohortId: number) {
    const cohortIdValue = String(cohortId)
    setUserDrafts((current) => {
      const nextDraft = { ...current[userId] }
      const currentCohortIds = nextDraft.cohort_ids ?? []
      nextDraft.cohort_ids = currentCohortIds.includes(cohortIdValue)
        ? currentCohortIds.filter((id) => id !== cohortIdValue)
        : [...currentCohortIds, cohortIdValue]

      return {
        ...current,
        [userId]: nextDraft,
      }
    })
  }

  const inviteRole = inviteDraft.role ?? 'participant'
  const inviteRequiresCohort = roleRequiresCohort(inviteRole)

  return (
    <section className="screen-grid admin-screen">
      <ScreenHeading
        eyebrow="Admin"
        title="Cohorts and invitations, without terminal commands."
        copy="Create the pilot cohorts, invite participants, and keep each user tied to the right Household CFO group before they sign in with Clerk."
      />

      {error && <p className="admin-alert error" role="alert">{error}</p>}
      {notice && <p className="admin-alert success">{notice}</p>}

      <div className="admin-stat-row">
        <AdminStat label="Cohorts" value={adminStats.cohorts.toString()} />
        <AdminStat label="Invited users" value={adminStats.users.toString()} />
        <AdminStat label="Pending" value={adminStats.pending.toString()} />
        <AdminStat label="Setup complete" value={adminStats.setupComplete.toString()} />
      </div>

      <RoleMatrix open={roleMatrixOpen} onToggle={setRoleMatrixOpen} />

      <div className="admin-layout">
        <article className="panel admin-card">
          <div className="admin-card-heading">
            <span className="spark" aria-hidden="true"><CohortIcon /></span>
            <div>
              <p className="eyebrow">Cohorts</p>
              <h3>Create the next group</h3>
            </div>
          </div>

          <form className="admin-form" onSubmit={handleCreateCohort}>
            <label className="admin-field wide">
              <span>Cohort name</span>
              <input value={createDraft.name} onChange={(event) => setCreateDraft((current) => ({ ...current, name: event.target.value }))} placeholder="Tuesday pilot cohort" />
            </label>
            <label className="admin-field">
              <span>Status</span>
              <select value={createDraft.status} onChange={(event) => setCreateDraft((current) => ({ ...current, status: event.target.value as AdminCohortStatus }))}>
                {cohortStatuses.map((status) => <option key={status} value={status}>{titleize(status)}</option>)}
              </select>
            </label>
            <label className="admin-field">
              <span>Starts</span>
              <input type="date" value={createDraft.starts_on ?? ''} onChange={(event) => setCreateDraft((current) => ({ ...current, starts_on: event.target.value }))} />
            </label>
            <label className="admin-field">
              <span>Ends</span>
              <input type="date" value={createDraft.ends_on ?? ''} onChange={(event) => setCreateDraft((current) => ({ ...current, ends_on: event.target.value }))} />
            </label>
            <label className="admin-field wide">
              <span>Notes</span>
              <textarea value={createDraft.notes ?? ''} onChange={(event) => setCreateDraft((current) => ({ ...current, notes: event.target.value }))} placeholder="Pilot focus, meeting cadence, or setup notes" rows={3} />
            </label>
            <button type="submit" disabled={cohortSaving}>{cohortSaving ? 'Saving' : 'Create cohort'}</button>
          </form>
        </article>

        <article className="panel admin-card">
          <div className="admin-card-heading">
            <span className="spark" aria-hidden="true"><UsersIcon /></span>
            <div>
              <p className="eyebrow">Cohort list</p>
              <h3>Select a group to manage</h3>
            </div>
          </div>

          {loading && cohorts.length === 0 ? (
            <p className="admin-muted">Loading cohorts and invitations...</p>
          ) : (
            <div className="cohort-list">
              <button type="button" className={`cohort-list-card ${selectedCohortId === null ? 'active' : ''}`} onClick={() => selectCohort(null)}>
                <strong>All users</strong>
                <span>Full invitation list</span>
              </button>
              {displayCohorts.map((cohort) => (
                <button type="button" className={`cohort-list-card ${selectedCohortId === cohort.id ? 'active' : ''}`} key={cohort.id} onClick={() => selectCohort(cohort.id)}>
                  <strong>{cohort.name}</strong>
                  <span>{titleize(cohort.status)} · {cohort.member_count} users · {cohort.setup_complete_count} ready</span>
                </button>
              ))}
            </div>
          )}
        </article>
      </div>

      <div className="admin-layout">
        <article className="panel admin-card">
          <div className="admin-card-heading">
            <span className="spark" aria-hidden="true"><CohortIcon /></span>
            <div>
              <p className="eyebrow">Selected cohort</p>
              <h3>{selectedCohort ? selectedCohort.name : 'No cohort selected'}</h3>
            </div>
          </div>

          {selectedCohort && editDraft ? (
            <form className="admin-form" onSubmit={handleUpdateCohort}>
              <div className="admin-cohort-summary">
                <AdminBadge value={titleize(selectedCohort.status)} tone={selectedCohort.status === 'active' ? 'green' : selectedCohort.status === 'archived' ? 'red' : 'gold'} />
                <span>{selectedCohort.participant_count} participants</span>
                <span>{selectedCohort.staff_count} staff</span>
                <span>{cohortDateRange(selectedCohort)}</span>
              </div>
              <label className="admin-field wide">
                <span>Name</span>
                <input value={editDraft.name} onChange={(event) => setEditDraft((current) => current ? { ...current, name: event.target.value } : current)} />
              </label>
              <label className="admin-field">
                <span>Status</span>
                <select value={editDraft.status} onChange={(event) => setEditDraft((current) => current ? { ...current, status: event.target.value as AdminCohortStatus } : current)}>
                  {cohortStatuses.map((status) => <option key={status} value={status}>{titleize(status)}</option>)}
                </select>
              </label>
              <label className="admin-field">
                <span>Starts</span>
                <input type="date" value={editDraft.starts_on ?? ''} onChange={(event) => setEditDraft((current) => current ? { ...current, starts_on: event.target.value } : current)} />
              </label>
              <label className="admin-field">
                <span>Ends</span>
                <input type="date" value={editDraft.ends_on ?? ''} onChange={(event) => setEditDraft((current) => current ? { ...current, ends_on: event.target.value } : current)} />
              </label>
              <label className="admin-field wide">
                <span>Notes</span>
                <textarea value={editDraft.notes ?? ''} onChange={(event) => setEditDraft((current) => current ? { ...current, notes: event.target.value } : current)} rows={3} />
              </label>
              <button type="submit" disabled={cohortSaving}>{cohortSaving ? 'Saving' : 'Save cohort'}</button>
            </form>
          ) : (
            <p className="admin-muted">Create a cohort, then select it here to update dates, status, and notes.</p>
          )}
        </article>

        <article className="panel admin-card">
          <div className="admin-card-heading">
            <span className="spark" aria-hidden="true"><ShieldIcon /></span>
            <div>
              <p className="eyebrow">Invite user</p>
              <h3>Add admin, coach, or participant</h3>
            </div>
          </div>

          <form className="admin-form" onSubmit={handleInviteUser}>
            <label className="admin-field wide">
              <span>Email</span>
              <input type="email" value={inviteDraft.email ?? ''} onChange={(event) => setInviteDraft((current) => ({ ...current, email: event.target.value }))} placeholder="name@example.com" />
            </label>
            <label className="admin-field">
              <span>First name</span>
              <input value={inviteDraft.first_name ?? ''} onChange={(event) => setInviteDraft((current) => ({ ...current, first_name: event.target.value }))} />
            </label>
            <label className="admin-field">
              <span>Last name</span>
              <input value={inviteDraft.last_name ?? ''} onChange={(event) => setInviteDraft((current) => ({ ...current, last_name: event.target.value }))} />
            </label>
            <label className="admin-field">
              <span>Role</span>
              <select value={inviteRole} onChange={(event) => setInviteDraft((current) => ({ ...current, role: event.target.value as UserRole }))}>
                {userRoles.map((role) => <option key={role} value={role}>{titleize(role)}</option>)}
              </select>
            </label>
            <label className="admin-field">
              <span>Cohort {inviteRequiresCohort ? '(required)' : '(optional)'}</span>
              <select required={inviteRequiresCohort} value={String(inviteDraft.cohort_id ?? '')} onChange={(event) => setInviteDraft((current) => ({ ...current, cohort_id: event.target.value }))}>
                <option value="">{inviteRequiresCohort ? 'Select a cohort' : 'No cohort for admin'}</option>
                {cohorts.map((cohort) => <option key={cohort.id} value={cohort.id}>{cohort.name}</option>)}
              </select>
            </label>
            <label className="admin-inline-check wide">
              <input
                type="checkbox"
                checked={inviteDraft.send_invitation_email ?? true}
                onChange={(event) => setInviteDraft((current) => ({ ...current, send_invitation_email: event.target.checked }))}
              />
              <span>Send invite email now</span>
            </label>
            <p className="admin-field-note wide">Admins can manage across cohorts without assignment. Active coaches and participants must belong to at least one cohort.</p>
            <button type="submit" disabled={inviteSaving}>{inviteSaving ? 'Creating invite' : 'Create invite'}</button>
          </form>
        </article>
      </div>

      <article className="panel admin-card admin-users-panel">
        <div className="admin-card-heading row-between">
          <div>
            <p className="eyebrow">Users</p>
            <h3>{selectedCohort ? `${selectedCohort.name} members` : 'All invited users'}</h3>
            <p className="admin-list-summary">Showing {visibleUsers.length} of {scopedUsers.length} users. Revoked users are hidden by default.</p>
          </div>
          <button type="button" className="admin-refresh" onClick={() => void loadAdminData()} disabled={loading}>{loading ? 'Refreshing' : 'Refresh'}</button>
        </div>

        <div className="admin-user-toolbar" aria-label="User filters and sorting">
          <label className="admin-field compact search-field">
            <span>Search</span>
            <input value={userSearch} onChange={(event) => setUserSearch(event.target.value)} placeholder="Name or email" />
          </label>
          <label className="admin-field compact">
            <span>Status</span>
            <select value={userStatusFilter} onChange={(event) => setUserStatusFilter(event.target.value as UserStatusFilter)}>
              <option value="active">Active only ({activeScopedUserCount})</option>
              <option value="pending">Pending</option>
              <option value="accepted">Accepted</option>
              <option value="revoked">Revoked</option>
              <option value="all">All statuses</option>
            </select>
          </label>
          <label className="admin-field compact">
            <span>Role</span>
            <select value={userRoleFilter} onChange={(event) => setUserRoleFilter(event.target.value as UserRoleFilter)}>
              <option value="all">All roles</option>
              {userRoles.map((role) => <option key={role} value={role}>{titleize(role)}</option>)}
            </select>
          </label>
          <label className="admin-field compact">
            <span>Sort</span>
            <select value={userSort} onChange={(event) => setUserSort(event.target.value as UserSortKey)}>
              <option value="name_asc">Name A–Z</option>
              <option value="email_asc">Email A–Z</option>
              <option value="role_asc">Role</option>
              <option value="status_asc">Status</option>
              <option value="setup_desc">Setup progress</option>
              <option value="invite_desc">Recent invite activity</option>
            </select>
          </label>
        </div>

        {visibleUsers.length === 0 ? (
          <p className="admin-muted">{scopedUsers.length === 0 ? 'No users in this view yet. Create an invite above to start the cohort.' : 'No users match these filters. Switch status to Revoked or All statuses when you need to review cancelled access.'}</p>
        ) : (
          <div className="admin-user-list">
            {visibleUsers.map((user) => {
              const draft = userDrafts[user.id] ?? adminDraftForUser(user)
              const isSelf = user.id === currentUser.id

              const draftNeedsCohort = cohortRequiredFor(draft.role, draft.invitation_status) && draft.cohort_ids.length === 0
              const draftRequiresCohort = cohortRequiredFor(draft.role, draft.invitation_status)
              const canResendInvite = user.invitation_status === 'pending'
              const canCancelInvite = user.invitation_status === 'pending' && !isSelf
              const canRemoveFromSelectedCohort = selectedCohortId !== null && serverCohortIdsForUser(user).includes(String(selectedCohortId)) && !isSelf
              const rowSaving = savingUserIds.has(user.id)
              const rowResending = resendingUserIds.has(user.id)

              return (
                <article className="admin-user-row" key={user.id}>
                  <div className="admin-user-main">
                    <div>
                      <strong>{user.full_name}</strong>
                      <span>{user.email}</span>
                    </div>
                    <div className="admin-badge-row">
                      <AdminBadge value={titleize(user.role)} tone={user.role === 'admin' ? 'green' : user.role === 'coach' ? 'gold' : 'neutral'} />
                      <AdminBadge value={titleize(user.invitation_status)} tone={user.invitation_status === 'accepted' ? 'green' : user.invitation_status === 'revoked' ? 'red' : 'gold'} />
                      <AdminBadge value={`Email ${titleize(user.invite_email.status)}`} tone={inviteEmailTone(user.invite_email.status)} />
                      <AdminBadge value={`${user.workspace.profile_completeness}% setup`} tone={user.workspace.setup_complete ? 'green' : 'neutral'} />
                    </div>
                    <p>{user.cohorts.map((membership) => membership.cohort.name).join(', ') || (user.role === 'admin' ? 'No cohort assigned; admin can work across cohorts' : 'No cohort assigned yet')}</p>
                    {user.invite_email.last_attempted_at && (
                      <p className="admin-email-line">Last email attempt: {shortDateTime(user.invite_email.last_attempted_at)}{user.invite_email.error ? ` · ${user.invite_email.error}` : ''}</p>
                    )}
                  </div>

                  <div className="admin-user-controls">
                    <label className="admin-field compact">
                      <span>Role</span>
                      <select value={draft.role} disabled={isSelf} onChange={(event) => updateUserDraft(user.id, 'role', event.target.value)}>
                        {userRoles.map((role) => <option key={role} value={role}>{titleize(role)}</option>)}
                      </select>
                    </label>
                    <label className="admin-field compact">
                      <span>Status</span>
                      <select value={draft.invitation_status} disabled={isSelf} onChange={(event) => updateUserDraft(user.id, 'invitation_status', event.target.value)}>
                        {invitationStatuses.map((status) => <option key={status} value={status}>{titleize(status)}</option>)}
                      </select>
                    </label>
                    <div className={`admin-field compact cohort-select ${draftNeedsCohort ? 'needs-attention' : ''}`}>
                      <span>Cohorts {draftRequiresCohort ? '(required)' : '(optional)'}</span>
                      <div className="admin-cohort-checks">
                        {cohorts.length === 0 && <small>No cohorts yet. Create one before adding coaches or participants.</small>}
                        {cohorts.map((cohort) => (
                          <label className="admin-cohort-check" key={cohort.id}>
                            <input
                              type="checkbox"
                              checked={draft.cohort_ids.includes(String(cohort.id))}
                              onChange={() => toggleUserCohort(user.id, cohort.id)}
                            />
                            <span>{cohort.name}</span>
                          </label>
                        ))}
                      </div>
                      {draftNeedsCohort && <small className="admin-field-warning">Required before saving.</small>}
                    </div>
                    <div className="admin-user-actions">
                      <button type="button" onClick={() => void handleSaveUser(user)} disabled={rowSaving || draftNeedsCohort}>{rowSaving ? 'Saving' : 'Save'}</button>
                      <button type="button" className="secondary-action" onClick={() => void handleResendInvitation(user)} disabled={!canResendInvite || rowResending}>{rowResending ? 'Sending' : 'Resend email'}</button>
                      {canCancelInvite && <button type="button" className="danger-action" onClick={() => void handleCancelInvite(user)} disabled={rowSaving}>Cancel invite</button>}
                      {canRemoveFromSelectedCohort && <button type="button" className="danger-action" onClick={() => void handleRemoveFromSelectedCohort(user)} disabled={rowSaving}>Remove from cohort</button>}
                    </div>
                  </div>
                </article>
              )
            })}
          </div>
        )}
      </article>
    </section>
  )
}

function AdminStat({ label, value }: { label: string; value: string }) {
  return (
    <article className="metric-card admin-stat-card">
      <span>{label}</span>
      <strong>{value}</strong>
    </article>
  )
}

function AdminBadge({ value, tone }: { value: string; tone: 'green' | 'gold' | 'red' | 'neutral' }) {
  return <span className={`admin-badge ${tone}`}>{value}</span>
}

function RoleMatrix({ open, onToggle }: { open: boolean; onToggle: (open: boolean) => void }) {
  return (
    <details className="role-matrix panel" open={open} onToggle={(event) => onToggle(event.currentTarget.open)}>
      <summary>
        <span>
          <strong>Role and cohort rules</strong>
          <small>Backend-enforced policy for admin, coach, and participant users.</small>
        </span>
      </summary>
      <div className="role-matrix-grid">
        <article>
          <strong>Admin</strong>
          <span>May have no cohort</span>
          <p>Can manage cohorts, users, invitations, and staff access. Admins are not limited to a single participant group.</p>
        </article>
        <article>
          <strong>Coach</strong>
          <span>Requires at least one active cohort</span>
          <p>Supports assigned groups and can create participant invites, but cannot manage admin or coach accounts. Revoked coaches can have no cohort.</p>
        </article>
        <article>
          <strong>Participant</strong>
          <span>Requires at least one active cohort</span>
          <p>Uses the household workspace and Mia coaching flow. Revoked participants can be removed from all cohorts.</p>
        </article>
      </div>
    </details>
  )
}

function adminDraftsForUsers(users: AdminUser[]) {
  return users.reduce<Record<number, AdminUserDraft>>((drafts, user) => {
    drafts[user.id] = adminDraftForUser(user)
    return drafts
  }, {})
}

function adminDraftForUser(user: AdminUser): AdminUserDraft {
  return {
    role: user.role,
    invitation_status: user.invitation_status,
    cohort_ids: serverCohortIdsForUser(user),
  }
}

function serverCohortIdsForUser(user: AdminUser) {
  return user.cohorts.map((membership) => String(membership.cohort.id))
}

function roleRequiresCohort(role: UserRole) {
  return role !== 'admin'
}

function cohortRequiredFor(role: UserRole, invitationStatus: InvitationStatus) {
  return roleRequiresCohort(role) && invitationStatus !== 'revoked'
}

function toggleIdInSet(current: Set<number>, id: number, enabled: boolean) {
  const next = new Set(current)
  if (enabled) next.add(id)
  else next.delete(id)
  return next
}

function cohortWithUserStats(cohort: AdminCohort, users: AdminUser[]): AdminCohort {
  const memberships = users.flatMap((user) => user.cohorts
    .filter((membership) => membership.cohort.id === cohort.id)
    .map((membership) => ({ user, membership })))

  return {
    ...cohort,
    member_count: memberships.length,
    participant_count: memberships.filter(({ membership }) => membership.role === 'participant').length,
    staff_count: memberships.filter(({ membership }) => membership.role === 'admin' || membership.role === 'coach').length,
  }
}

function filterAndSortAdminUsers(users: AdminUser[], filters: { search: string; status: UserStatusFilter; role: UserRoleFilter; sort: UserSortKey }) {
  const search = filters.search.trim().toLowerCase()
  const filtered = users.filter((user) => {
    const statusMatches = filters.status === 'all'
      ? true
      : filters.status === 'active'
        ? user.invitation_status !== 'revoked'
        : user.invitation_status === filters.status
    const roleMatches = filters.role === 'all' || user.role === filters.role
    const searchMatches = !search || `${user.full_name} ${user.email}`.toLowerCase().includes(search)

    return statusMatches && roleMatches && searchMatches
  })

  return [...filtered].sort((left, right) => compareAdminUsers(left, right, filters.sort))
}

function compareAdminUsers(left: AdminUser, right: AdminUser, sort: UserSortKey) {
  if (sort === 'email_asc') return left.email.localeCompare(right.email)
  if (sort === 'role_asc') return compareTextThenName(left.role, right.role, left, right)
  if (sort === 'status_asc') return compareTextThenName(left.invitation_status, right.invitation_status, left, right)
  if (sort === 'setup_desc') return right.workspace.profile_completeness - left.workspace.profile_completeness || compareByName(left, right)
  if (sort === 'invite_desc') return sortableTime(right.invite_email.last_attempted_at) - sortableTime(left.invite_email.last_attempted_at) || compareByName(left, right)

  return compareByName(left, right)
}

function compareTextThenName(leftValue: string, rightValue: string, leftUser: AdminUser, rightUser: AdminUser) {
  return leftValue.localeCompare(rightValue) || compareByName(leftUser, rightUser)
}

function compareByName(left: AdminUser, right: AdminUser) {
  return left.full_name.localeCompare(right.full_name) || left.email.localeCompare(right.email)
}

function sortableTime(value: string | null) {
  return value ? new Date(value).getTime() : 0
}

function inviteActionNotice(response: AdminUserMutationResponse) {
  if (response.reactivated) return 'was reactivated'
  if (response.created === false) return 'was updated'

  return 'is invited'
}

function inviteDeliveryNotice(response: AdminUserMutationResponse) {
  if (response.invitation_sent) return 'Invite email sent through Resend.'
  if (response.invitation_status === 'failed') return `Invite saved, but email delivery failed${response.invitation_error ? `: ${response.invitation_error}` : '.'}`
  if (response.invitation_status === 'skipped') return 'Invite saved; email delivery was skipped by admin.'

  return 'Invite saved.'
}

function inviteEmailTone(status: AdminUser['invite_email']['status']): 'green' | 'gold' | 'red' | 'neutral' {
  if (status === 'sent') return 'green'
  if (status === 'failed') return 'red'
  if (status === 'skipped') return 'gold'

  return 'neutral'
}

function shortDateTime(value: string) {
  return new Intl.DateTimeFormat('en-US', {
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  }).format(new Date(value))
}

function cleanCohortDraft(draft: AdminCohortInput): AdminCohortInput {
  return {
    name: draft.name.trim(),
    status: draft.status,
    starts_on: draft.starts_on || '',
    ends_on: draft.ends_on || '',
    notes: draft.notes?.trim() ?? '',
  }
}

function cohortDraftFor(cohort: AdminCohort | null): AdminCohortInput | null {
  if (!cohort) return null

  return {
    name: cohort.name,
    status: cohort.status,
    starts_on: cohort.starts_on ?? '',
    ends_on: cohort.ends_on ?? '',
    notes: cohort.notes ?? '',
  }
}

function titleize(value: string) {
  return value.replace(/_/g, ' ').replace(/\b\w/g, (letter) => letter.toUpperCase())
}

function cohortDateRange(cohort: AdminCohort) {
  if (cohort.starts_on && cohort.ends_on) return `${formatShortDate(cohort.starts_on)} – ${formatShortDate(cohort.ends_on)}`
  if (cohort.starts_on) return `Starts ${formatShortDate(cohort.starts_on)}`
  if (cohort.ends_on) return `Ends ${formatShortDate(cohort.ends_on)}`

  return 'Dates not set'
}

function formatShortDate(value: string) {
  return new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', year: 'numeric' }).format(new Date(`${value}T00:00:00`))
}

function monthIndexFromIsoDate(value: string) {
  const date = new Date(`${value}T00:00:00Z`)
  return Number.isNaN(date.getTime()) ? new Date().getMonth() : date.getUTCMonth()
}

function messageLengthBucket(length: number) {
  if (length < 80) return 'under_80'
  if (length < 250) return '80_249'
  if (length < 750) return '250_749'
  return '750_plus'
}

function WorkspaceSetupForm({
  formRef,
  values,
  editing,
  saving,
  error,
  onBeginEdit,
  onCancel,
  onChange,
  onSubmit,
}: {
  formRef?: Ref<HTMLFormElement>
  values: WorkspaceSetupValues
  editing: boolean
  saving: boolean
  error: string | null
  onBeginEdit: () => void
  onCancel: () => void
  onChange: (key: keyof WorkspaceSetupValues, value: string) => void
  onSubmit: (event: FormEvent<HTMLFormElement>) => void
}) {
  return (
    <form ref={formRef} className="panel setup-form" onSubmit={onSubmit}>
      <div className="row-between setup-form-heading">
        <div>
          <p className="eyebrow">Real workspace</p>
          <h3>{editing ? 'Editing household numbers' : 'Saved household numbers'}</h3>
          <p>{editing ? 'Save when the changes are intentional. Mia will use the updated context after you confirm.' : 'Review first. Click Edit profile before changing the numbers Mia uses as context.'}</p>
        </div>
        <div className="setup-form-actions">
          {editing ? (
            <>
              <button type="button" className="secondary-button" disabled={saving} onClick={onCancel}>Cancel</button>
              <button type="submit" disabled={saving}>{saving ? 'Saving' : 'Save numbers'}</button>
            </>
          ) : (
            <button type="button" onClick={onBeginEdit}>Edit profile</button>
          )}
        </div>
      </div>

      <div className="setup-field-grid">
        <label className="setup-field text-wide" title="The household name Mia should use in this workspace.">
          <span>Household name</span>
          <input name="household_name" value={values.household_name} disabled={!editing} onChange={(event) => onChange('household_name', event.target.value)} />
          <small>The name Mia should use for this household.</small>
        </label>
        <label className="setup-field text-wide" title="The money goal or life decision Mia should keep in mind when coaching you.">
          <span>Primary goal</span>
          <textarea name="primary_goal" rows={3} value={values.primary_goal} disabled={!editing} onChange={(event) => onChange('primary_goal', event.target.value)} />
          <small>Write the goal, worry, or decision Mia should coach around. This box grows for longer notes.</small>
        </label>
        <MoneyInput disabled={!editing} name="primary_income" label="Primary monthly income" value={values.primary_income} help="Regular take-home income from jobs or steady paychecks, after taxes if possible." onChange={(value) => onChange('primary_income', value)} />
        <MoneyInput disabled={!editing} name="business_income" label="Business monthly income" value={values.business_income} help="Average monthly net income from side work, business, rental, or self-employment." onChange={(value) => onChange('business_income', value)} />
        <MoneyInput disabled={!editing} name="fixed_expenses" label="Fixed essentials" value={values.fixed_expenses} help="Monthly must-pay bills: rent or mortgage, utilities, insurance, phone, transportation, and basic household needs." onChange={(value) => onChange('fixed_expenses', value)} />
        <MoneyInput disabled={!editing} name="flexible_spend" label="Flexible spending" value={values.flexible_spend} help="Monthly spending you can shape: groceries, dining out, shopping, subscriptions, activities, and other wants." onChange={(value) => onChange('flexible_spend', value)} />
        <MoneyInput disabled={!editing} name="expected_sinking_fund" label="Expected sinking fund" value={values.expected_sinking_fund} help="Monthly set-aside for known irregular costs like car registration, holidays, tuition, travel, or back-to-school." onChange={(value) => onChange('expected_sinking_fund', value)} />
        <MoneyInput disabled={!editing} name="unexpected_sinking_fund" label="Unexpected sinking fund" value={values.unexpected_sinking_fund} help="Monthly buffer for life-happens costs like repairs, medical bills, family support, or emergency travel." onChange={(value) => onChange('unexpected_sinking_fund', value)} />
        <MoneyInput disabled={!editing} name="emergency_fund" label="Emergency fund" value={values.emergency_fund} help="Current cash set aside for emergencies or runway, not your monthly contribution." onChange={(value) => onChange('emergency_fund', value)} />
        <MoneyInput disabled={!editing} name="other_assets" label="Other assets" value={values.other_assets} help="Other savings or investment balances you want included in net worth. Skip home value unless you want it tracked." onChange={(value) => onChange('other_assets', value)} />
        <MoneyInput disabled={!editing} name="credit_card_debt" label="Credit card debt" value={values.credit_card_debt} help="Current credit card balance you want Mia to include in payoff decisions." onChange={(value) => onChange('credit_card_debt', value)} />
        <MoneyInput disabled={!editing} name="debt_payment" label="Debt minimum payment" value={values.debt_payment} help="Total monthly minimum payment required for the debt entered above." onChange={(value) => onChange('debt_payment', value)} />
        <label className="setup-field" title="How many months of expenses you want protected in cash runway.">
          <span>Target runway months</span>
          <input
            type="number"
            min="0"
            step="0.5"
            name="target_runway_months"
            value={values.target_runway_months}
            disabled={!editing}
            onChange={(event) => onChange('target_runway_months', event.target.value)}
          />
          <small>How many months of expenses you want protected before bigger moves.</small>
        </label>
      </div>

      {error && <p className="setup-error" role="alert">{error}</p>}
    </form>
  )
}

function MoneyInput({ disabled = false, name, label, value, help, onChange }: { disabled?: boolean; name: keyof WorkspaceSetupValues; label: string; value: number; help: string; onChange: (value: string) => void }) {
  return (
    <label className="setup-field" title={help}>
      <span>{label}</span>
      <input name={name} type="number" min="0" step="1" value={value} disabled={disabled} onChange={(event) => onChange(event.target.value)} />
      <small>{help}</small>
    </label>
  )
}

function allocationDraftKey(month: BudgetCategoryMonth) {
  return String(month.allocation_id ?? `missing:${month.period_id}`)
}

function categoryDraftKey(row: BudgetCategoryRow) {
  return String(row.id)
}

function allocationDraftValue(month: BudgetCategoryMonth, allocationDrafts: Record<string, string>) {
  return allocationDrafts[allocationDraftKey(month)] ?? String(month.planned)
}

function categoryDraftValue(row: BudgetCategoryRow, categoryDrafts: Record<string, { name: string; stack_key: BudgetStackKey }>) {
  return categoryDrafts[categoryDraftKey(row)] ?? { name: row.name, stack_key: row.stack_key }
}

function annualBudgetPlanSignature(plan: AnnualBudgetPlan) {
  return plan.rows.map((row) => (
    `${row.id}:${row.name}:${row.stack_key}:${row.months.map((month) => `${month.allocation_id ?? 'missing'}-${month.period_id}-${month.planned}`).join(',')}`
  )).join('|')
}

function budgetAllocationChanges(rows: BudgetCategoryRow[], allocationDrafts: Record<string, string>): BudgetAllocationChange[] {
  return rows.flatMap((row) => row.months.flatMap((month) => {
    if (!month.allocation_id || month.allocation_missing) return []

    const draftedValue = allocationDrafts[allocationDraftKey(month)]
    if (draftedValue === undefined || Number(draftedValue || 0) === month.planned) return []

    return [{
      allocation_id: month.allocation_id,
      planned_amount: draftedValue || '0',
      category_id: row.id,
      stack_key: row.stack_key,
    }]
  }))
}

function budgetCategoryChanges(rows: BudgetCategoryRow[], categoryDrafts: Record<string, { name: string; stack_key: BudgetStackKey }>): BudgetCategoryChange[] {
  return rows.flatMap((row) => {
    const draftedValue = categoryDrafts[categoryDraftKey(row)]
    if (!draftedValue) return []

    const name = draftedValue.name.trim()
    if (!name || (name === row.name && draftedValue.stack_key === row.stack_key)) return []

    return [{ id: row.id, name, stack_key: draftedValue.stack_key }]
  })
}

function MiaActionDraftReviewStack({
  drafts,
  isRealWorkspace,
  action,
  compact = false,
  draftActionsDisabled = false,
  disabledReason,
  onApply,
  onCancel,
}: {
  drafts: MiaActionDraft[]
  isRealWorkspace: boolean
  action: string | null
  compact?: boolean
  draftActionsDisabled?: boolean
  disabledReason?: string
  onApply: (draft: MiaActionDraft) => void
  onCancel: (draft: MiaActionDraft) => void
}) {
  return (
    <div className={`mia-action-draft-stack ${compact ? 'compact' : ''}`}>
      <div>
        <p className="eyebrow">Review before applying</p>
        <h4>Mia drafted budget edits for your approval</h4>
        {compact && <p>Apply only if the planned-dollar changes are right. Actual spending does not change from these drafts.</p>}
        {disabledReason && <p className="transaction-draft-disabled-reason">{disabledReason}</p>}
      </div>
      {drafts.map((draft) => (
        <MiaActionDraftReviewCard
          key={miaActionDraftRenderKey(draft)}
          draft={draft}
          isRealWorkspace={isRealWorkspace}
          action={action}
          draftActionsDisabled={draftActionsDisabled}
          onApply={onApply}
          onCancel={onCancel}
        />
      ))}
    </div>
  )
}

function MiaActionDraftReviewCard({
  draft,
  isRealWorkspace,
  action,
  draftActionsDisabled,
  onApply,
  onCancel,
}: {
  draft: MiaActionDraft
  isRealWorkspace: boolean
  action: string | null
  draftActionsDisabled: boolean
  onApply: (draft: MiaActionDraft) => void
  onCancel: (draft: MiaActionDraft) => void
}) {
  const isPending = draft.status === 'pending'
  const actionsDisabled = !isRealWorkspace || draftActionsDisabled || !isPending

  return (
    <div className="mia-action-draft-card">
      <div className="mia-action-draft-main">
        <div className="transaction-draft-title-row">
          <strong>{draft.title}</strong>
          <span className={`document-status ${draft.status === 'pending' ? 'gold' : draft.status === 'applied' ? 'green' : 'red'}`}>{titleize(draft.status)}</span>
        </div>
        <p>{draft.summary}</p>
        {draft.rationale && <p>{draft.rationale}</p>}
        <div className="mia-action-item-list">
          {draft.items.map((item) => (
            <div className="mia-action-item" key={item.id}>
              <strong>{item.label}</strong>
              {item.description && <span>{item.description}</span>}
              {miaActionItemFinePrint(item) && <small>{miaActionItemFinePrint(item)}</small>}
            </div>
          ))}
        </div>
        <small className="mia-action-safety-copy">You stay the Household CFO. We’ll check the draft again when you apply it, save a record of the change, and leave actual spending untouched.</small>
      </div>
      {isPending ? (
        <div className="mia-action-draft-actions">
          <button type="button" disabled={actionsDisabled || action === `apply-mia-action:${draft.id}`} onClick={() => onApply(draft)}>
            {action === `apply-mia-action:${draft.id}` ? 'Applying' : 'Apply budget edit'}
          </button>
          <button type="button" className="secondary-button" disabled={actionsDisabled || action === `cancel-mia-action:${draft.id}`} onClick={() => onCancel(draft)}>
            {action === `cancel-mia-action:${draft.id}` ? 'Canceling' : 'Cancel draft'}
          </button>
        </div>
      ) : (
        <div className="mia-action-draft-actions terminal">
          <span>{draft.status === 'applied' ? 'Applied to planned budget. Actuals did not change.' : 'Canceled. No budget numbers changed.'}</span>
        </div>
      )}
    </div>
  )
}

function miaActionDraftRenderKey(draft: MiaActionDraft) {
  return [draft.id, draft.status, draft.items.map((item) => `${item.id}:${item.label}`).join(',')].join('|')
}

function miaActionItemFinePrint(item: MiaActionItem) {
  if (item.action_type !== 'update_allocation') return null

  const changes = Array.isArray(item.payload.changes) ? item.payload.changes : []
  if (changes.length === 0) return null
  if (changes.length === 12) return 'Applies to every month in the selected budget year.'
  return `Applies to ${changes.length} month${changes.length === 1 ? '' : 's'}.`
}

function TransactionDraftReviewStack({
  drafts,
  isRealWorkspace,
  action,
  compact = false,
  draftActionsDisabled = false,
  disabledReason,
  categories = [],
  onUpdate,
  onMatch,
  onConfirm,
  onIgnore,
  onReopen,
}: {
  drafts: TransactionDraft[]
  isRealWorkspace: boolean
  action: string | null
  compact?: boolean
  draftActionsDisabled?: boolean
  disabledReason?: string
  categories?: BudgetCategoryRow[]
  onUpdate?: (draft: TransactionDraft, values: TransactionDraftUpdateInput) => Promise<void> | void
  onMatch?: (draft: TransactionDraft, matchId?: number) => void
  onConfirm: (draft: TransactionDraft) => void
  onIgnore: (draft: TransactionDraft) => void
  onReopen: (draft: TransactionDraft) => void
}) {
  const [query, setQuery] = useState('')
  const [page, setPage] = useState(0)
  const [pageSize, setPageSize] = useState(compact ? 5 : 10)
  const filteredDrafts = useMemo(() => {
    const normalizedQuery = query.trim().toLowerCase()
    if (!normalizedQuery) return drafts

    return drafts.filter((draft) => [
      draft.merchant,
      draft.occurred_on,
      draft.category_name ?? '',
      ...(draft.splits ?? []).map((split) => split.category_name ?? ''),
      exactMoneyNumber(draft.amount, draft.amount_cents).toFixed(2),
    ].join(' ').toLowerCase().includes(normalizedQuery))
  }, [drafts, query])
  const totalPages = Math.max(1, Math.ceil(filteredDrafts.length / pageSize))
  const safePage = Math.min(page, totalPages - 1)
  const pageStart = safePage * pageSize
  const visibleDrafts = filteredDrafts.slice(pageStart, pageStart + pageSize)

  return (
    <div className={`transaction-draft-stack ${compact ? 'compact' : ''}`}>
      <div className="transaction-draft-stack-heading">
        <div>
          <p className="eyebrow">Review before applying</p>
          <h4>Mia drafted transactions for your approval</h4>
          {compact && <p>Confirm only if the merchant, amount, split, and category are right. Actuals do not change until you approve.</p>}
          {disabledReason && <p className="transaction-draft-disabled-reason">{disabledReason}</p>}
        </div>
        <strong>{drafts.length} review{drafts.length === 1 ? '' : 's'}</strong>
      </div>

      {drafts.length > 5 && (
        <div className="transaction-draft-queue-controls" aria-label="Transaction review queue controls">
          <label>
            <span className="sr-only">Search transaction reviews</span>
            <input
              type="search"
              value={query}
              placeholder="Search merchant, category, date, or amount"
              onChange={(event) => {
                setQuery(event.currentTarget.value)
                setPage(0)
              }}
            />
          </label>
          <label>
            <span>Show</span>
            <select value={pageSize} onChange={(event) => { setPageSize(Number(event.currentTarget.value)); setPage(0) }}>
              <option value={5}>5</option>
              <option value={10}>10</option>
              <option value={25}>25</option>
            </select>
          </label>
        </div>
      )}

      {visibleDrafts.length === 0 ? (
        <div className="transaction-draft-empty-filter">
          <strong>No transaction reviews match that search.</strong>
          <button type="button" className="secondary-button" onClick={() => { setQuery(''); setPage(0) }}>Clear search</button>
        </div>
      ) : visibleDrafts.map((draft) => (
        <TransactionDraftReviewCard
          key={transactionDraftRenderKey(draft)}
          draft={draft}
          isRealWorkspace={isRealWorkspace}
          action={action}
          draftActionsDisabled={draftActionsDisabled}
          categories={categories}
          onUpdate={onUpdate}
          onMatch={onMatch}
          onConfirm={onConfirm}
          onIgnore={onIgnore}
          onReopen={onReopen}
        />
      ))}

      {filteredDrafts.length > pageSize && (
        <nav className="transaction-draft-pagination" aria-label="Transaction review pages">
          <span>
            {pageStart + 1}–{Math.min(pageStart + pageSize, filteredDrafts.length)} of {filteredDrafts.length}
          </span>
          <div>
            <button type="button" className="secondary-button" disabled={safePage === 0} onClick={() => setPage(Math.max(0, safePage - 1))}>Previous</button>
            <span aria-live="polite">Page {safePage + 1} of {totalPages}</span>
            <button type="button" className="secondary-button" disabled={safePage >= totalPages - 1} onClick={() => setPage(Math.min(totalPages - 1, safePage + 1))}>Next</button>
          </div>
        </nav>
      )}
    </div>
  )
}

type EditableDraftSplit = {
  id?: number
  amount: string
  budget_category_id: string
  category_name: string
  stack_key: BudgetStackKey | ''
  notes: string
}

function TransactionDraftReviewCard({
  draft,
  isRealWorkspace,
  action,
  draftActionsDisabled,
  categories,
  onUpdate,
  onMatch,
  onConfirm,
  onIgnore,
  onReopen,
}: {
  draft: TransactionDraft
  isRealWorkspace: boolean
  action: string | null
  draftActionsDisabled: boolean
  categories: BudgetCategoryRow[]
  onUpdate?: (draft: TransactionDraft, values: TransactionDraftUpdateInput) => Promise<void> | void
  onMatch?: (draft: TransactionDraft, matchId?: number) => void
  onConfirm: (draft: TransactionDraft) => void
  onIgnore: (draft: TransactionDraft) => void
  onReopen: (draft: TransactionDraft) => void
}) {
  const [editing, setEditing] = useState(false)
  const [merchant, setMerchant] = useState(draft.merchant)
  const [occurredOn, setOccurredOn] = useState(draft.occurred_on)
  const [amount, setAmount] = useState(editableAmountForDraft(draft))
  const [splits, setSplits] = useState<EditableDraftSplit[]>(() => editableSplitsForDraft(draft))
  const [editError, setEditError] = useState<string | null>(null)
  const activeCategories = categories.filter((category) => category.active)
  const isPending = draft.status === 'pending'
  const proposedMatches = isPending ? (draft.matches ?? []).filter((match) => match.status === 'proposed') : []
  const displayAmount = exactMoneyNumber(draft.amount, draft.amount_cents)
  const splitTotal = splits.reduce((sum, split) => sum + Number(split.amount || 0), 0)
  const targetAmount = Number(amount || 0)
  const splitMismatch = Math.round(splitTotal * 100) !== Math.round(targetAmount * 100)
  const saving = action === `update-draft:${draft.id}`
  const reopening = action === `reopen-draft:${draft.id}`
  const actionsDisabled = !isRealWorkspace || draftActionsDisabled || !isPending
  const reopenDisabled = !isRealWorkspace || draftActionsDisabled || isPending

  function resetEditorFromDraft() {
    setMerchant(draft.merchant)
    setOccurredOn(draft.occurred_on)
    setAmount(editableAmountForDraft(draft))
    setSplits(editableSplitsForDraft(draft))
    setEditError(null)
  }

  function beginEditing() {
    resetEditorFromDraft()
    setEditing(true)
  }

  function closeEditing() {
    resetEditorFromDraft()
    setEditing(false)
  }

  function updateSplit(index: number, values: Partial<EditableDraftSplit>) {
    setSplits((current) => current.map((split, candidateIndex) => (candidateIndex === index ? { ...split, ...values } : split)))
  }

  function addSplit() {
    setSplits((current) => ([
      ...current,
      { amount: '', budget_category_id: '', category_name: '', stack_key: '', notes: '' },
    ]))
  }

  function removeSplit(index: number) {
    setSplits((current) => current.length <= 1 ? current : current.filter((_, candidateIndex) => candidateIndex !== index))
  }

  async function saveDraftEdits() {
    if (!onUpdate) return

    const cleanedSplits = splits.filter((split) => split.id || split.amount || split.budget_category_id || split.category_name || split.stack_key || split.notes)
    if (cleanedSplits.length === 0) {
      setEditError('Add at least one split before saving this draft.')
      return
    }

    setEditError(null)
    try {
      await onUpdate(draft, {
        occurred_on: occurredOn,
        merchant,
        amount,
        splits: cleanedSplits.map((split) => ({
          id: split.id,
          amount: split.amount,
          budget_category_id: split.budget_category_id ? Number(split.budget_category_id) : null,
          category_name: split.category_name || null,
          stack_key: split.stack_key || null,
          notes: split.notes || null,
        })),
      })
      setEditing(false)
    } catch (caught) {
      setEditError(caught instanceof Error ? caught.message : 'Transaction draft could not be updated.')
    }
  }

  return (
    <div className="transaction-draft-card">
      <div className="transaction-draft-main">
        <div className="transaction-draft-title-row">
          <strong>{draft.merchant}</strong>
          <span className={`document-status ${transactionDraftStatusTone(draft.status)}`}>{titleize(draft.status)}</span>
        </div>
        <p>{formatShortDate(draft.occurred_on)} · {currency.format(displayAmount)} · {draft.category_name ?? 'Needs category'}</p>
        {(draft.splits ?? []).length > 0 && (
          <div className="transaction-draft-splits">
            {(draft.splits ?? []).map((split) => (
              <span key={split.id}>{split.category_name ?? 'Needs category'} {currency.format(exactMoneyNumber(split.amount, split.amount_cents))}</span>
            ))}
          </div>
        )}
        {proposedMatches.length > 0 && (
          <div className="transaction-match-suggestions">
            {proposedMatches.slice(0, 2).map((match) => (
              <div key={match.id}>
                <span>Possible duplicate: {match.transaction.merchant} · {formatShortDate(match.transaction.occurred_on)} · {currency.format(match.transaction.amount)}</span>
                {onMatch && (
                  <button type="button" className="secondary-button" disabled={actionsDisabled || action === `match-draft:${draft.id}`} onClick={() => onMatch(draft, match.id)}>
                    {action === `match-draft:${draft.id}` ? 'Matching' : 'Match existing'}
                  </button>
                )}
              </div>
            ))}
          </div>
        )}
      </div>

      {editing && isPending && (
        <div className="transaction-draft-editor">
          <label>
            <span>Merchant</span>
            <input value={merchant} onChange={(event) => setMerchant(event.currentTarget.value)} />
          </label>
          <label>
            <span>Date</span>
            <input type="date" value={occurredOn} onChange={(event) => setOccurredOn(event.currentTarget.value)} />
          </label>
          <label>
            <span>Total</span>
            <input type="number" min="0.01" step="0.01" value={amount} onChange={(event) => setAmount(event.currentTarget.value)} />
          </label>
          <div className="transaction-split-editor-list">
            {splits.map((split, index) => (
              <div className="transaction-split-editor" key={split.id ?? `new-${index}`}>
                <label>
                  <span>Split amount</span>
                  <input type="number" min="0.01" step="0.01" value={split.amount} onChange={(event) => updateSplit(index, { amount: event.currentTarget.value })} />
                </label>
                <label>
                  <span>Category</span>
                  <select value={split.budget_category_id} onChange={(event) => {
                    const category = activeCategories.find((candidate) => String(candidate.id) === event.currentTarget.value)
                    updateSplit(index, {
                      budget_category_id: event.currentTarget.value,
                      category_name: category?.name ?? split.category_name,
                      stack_key: category?.stack_key ?? split.stack_key,
                    })
                  }}>
                    <option value="">Needs category</option>
                    {activeCategories.map((category) => <option key={category.id} value={category.id}>{category.name}</option>)}
                  </select>
                </label>
                <label>
                  <span>Notes</span>
                  <input value={split.notes} onChange={(event) => updateSplit(index, { notes: event.currentTarget.value })} />
                </label>
                <button type="button" className="secondary-button" disabled={splits.length <= 1} onClick={() => removeSplit(index)}>Remove</button>
              </div>
            ))}
          </div>
          <div className="transaction-draft-edit-actions">
            <button type="button" className="secondary-button" onClick={addSplit}>Add split</button>
            {splitMismatch && <span className="transaction-draft-disabled-reason">Splits total {currency.format(splitTotal)} but draft total is {currency.format(targetAmount)}.</span>}
            {editError && <span className="transaction-draft-disabled-reason" role="alert">{editError}</span>}
            <button type="button" className="secondary-button" onClick={closeEditing}>Cancel</button>
            <button type="button" disabled={saving || splitMismatch} onClick={() => void saveDraftEdits()}>{saving ? 'Saving' : 'Save draft'}</button>
          </div>
        </div>
      )}

      {isPending ? (
        <div className="transaction-draft-actions">
          {onUpdate && <button type="button" className="secondary-button" disabled={actionsDisabled || saving} onClick={editing ? closeEditing : beginEditing}>{editing ? 'Close edit' : 'Edit'}</button>}
          <button type="button" disabled={actionsDisabled || action === `confirm-draft:${draft.id}`} onClick={() => onConfirm(draft)}>
            {action === `confirm-draft:${draft.id}` ? 'Confirming' : 'Confirm'}
          </button>
          <button type="button" className="secondary-button" disabled={actionsDisabled || action === `ignore-draft:${draft.id}`} onClick={() => onIgnore(draft)}>
            {action === `ignore-draft:${draft.id}` ? 'Ignoring' : 'Ignore'}
          </button>
        </div>
      ) : (
        <div className="transaction-draft-actions terminal">
          <span>{transactionDraftTerminalCopy(draft.status)}</span>
          <button type="button" className="secondary-button" disabled={reopenDisabled || reopening} onClick={() => onReopen(draft)}>
            {reopening ? 'Reopening' : transactionDraftReopenLabel(draft.status)}
          </button>
        </div>
      )}
    </div>
  )
}

function transactionDraftStatusTone(status: TransactionDraft['status']) {
  if (status === 'pending') return 'gold'
  if (status === 'ignored') return 'red'
  return 'green'
}

function transactionDraftTerminalCopy(status: TransactionDraft['status']) {
  if (status === 'matched') return 'Matched to an existing actual. No new spending was added.'
  if (status === 'ignored') return 'Ignored. Actuals did not change.'
  if (status === 'corrected') return 'Confirmed with edits. Actuals were updated.'
  if (status === 'confirmed') return 'Confirmed. Actuals were updated.'
  return 'Review complete.'
}

function transactionDraftReopenLabel(status: TransactionDraft['status']) {
  if (status === 'matched') return 'Undo match'
  if (status === 'ignored') return 'Restore draft'
  return 'Undo to edit'
}

function transactionDraftRenderKey(draft: TransactionDraft) {
  return [
    draft.id,
    draft.status,
    draft.occurred_on,
    draft.merchant,
    draft.amount_cents ?? draft.amount,
    (draft.splits ?? []).map((split) => `${split.id}:${split.amount_cents}:${split.budget_category_id}`).join(','),
    (draft.matches ?? []).map((match) => `${match.id}:${match.status}`).join(','),
  ].join('|')
}

function editableAmountForDraft(draft: TransactionDraft) {
  return exactMoneyString(draft.amount, draft.amount_cents)
}

function exactMoneyString(value: number, cents?: number | null) {
  return exactMoneyNumber(value, cents).toFixed(2)
}

function exactMoneyNumber(value: number, cents?: number | null) {
  if (typeof cents === 'number') return cents / 100
  return Number.isFinite(value) ? value : 0
}

function editableSplitsForDraft(draft: TransactionDraft): EditableDraftSplit[] {
  const splits = draft.splits && draft.splits.length > 0
    ? draft.splits
    : [{ id: undefined, amount: draft.amount, amount_cents: draft.amount_cents ?? null, budget_category_id: draft.category_id, category_name: draft.category_name, stack_key: null, notes: null }]

  return splits.map((split) => ({
    id: split.id,
    amount: exactMoneyString(split.amount, split.amount_cents),
    budget_category_id: split.budget_category_id ? String(split.budget_category_id) : '',
    category_name: split.category_name ?? '',
    stack_key: split.stack_key ?? '',
    notes: split.notes ?? '',
  }))
}

function CurrentMonthActivityPanel({
  plan,
  currentMonthIndex,
  spendingReport,
  loading,
  error,
}: {
  plan: AnnualBudgetPlan
  currentMonthIndex: number
  spendingReport: SpendingReport | null
  loading: boolean
  error: string | null
}) {
  const month = plan.months[currentMonthIndex]
  const pendingByCategory = useMemo(() => {
    const totals: Record<string, number> = {}
    plan.pending_transaction_drafts.forEach((draft) => {
      if (!month || !draft.category_id || !draftOccursInMonth(draft, month)) return

      totals[String(draft.category_id)] = (totals[String(draft.category_id)] ?? 0) + draft.amount
    })
    return totals
  }, [month, plan.pending_transaction_drafts])
  const rows = spendingReport?.categories.map((category) => ({
    id: category.id,
    name: category.name,
    stackLabel: category.stack_label,
    planned: category.planned,
    actual: category.actual,
    remaining: category.remaining,
    pending: category.pending,
    active: category.active ?? true,
  })) ?? plan.rows.map((row) => {
    const cell = row.months[currentMonthIndex]
    return {
      id: row.id,
      name: row.name,
      stackLabel: row.stack_label,
      planned: cell?.planned ?? 0,
      actual: cell?.actual ?? 0,
      remaining: cell?.remaining ?? 0,
      pending: pendingByCategory[String(row.id)] ?? 0,
      active: row.active,
    }
  })
  const totalPending = spendingReport?.totals.pending ?? rows.reduce((sum, row) => sum + row.pending, 0)

  return (
    <section className="current-month-activity" aria-label={`${month?.label ?? 'Current month'} activity`}>
      <div className="current-month-activity-heading">
        <div>
          <p className="eyebrow">{month?.label ?? 'Current month'} operating view</p>
          <h4>Planned, actual, and pending review</h4>
        </div>
        {loading ? <span>Loading report</span> : totalPending > 0 && <span>{currency.format(totalPending)} waiting for review</span>}
      </div>
      {error && <p className="setup-error" role="alert">{error}</p>}
      <div className="month-activity-list">
        {rows.map((row) => (
          <div className="month-activity-row" key={row.id}>
            <div>
              <strong>{row.name}</strong>
              <span>{row.stackLabel}{row.active ? '' : ' · Archived'}</span>
            </div>
            <div className="month-activity-amounts">
              <span><b>{currency.format(row.planned)}</b> planned</span>
              <span><b>{currency.format(row.actual)}</b> actual</span>
              <span><b>{currency.format(row.remaining)}</b> remaining</span>
              {row.pending > 0 && <span className="pending"><b>{currency.format(row.pending)}</b> pending</span>}
            </div>
          </div>
        ))}
      </div>
      {spendingReport && <SpendingReportLedger report={spendingReport} />}
    </section>
  )
}

function SpendingReportLedger({ report }: { report: SpendingReport }) {
  return (
    <div className="spending-report-ledger">
      <div className="spending-report-summary">
        <span>{report.period_label}</span>
        <strong>{currency.format(report.totals.actual)} actual</strong>
        <span>{currency.format(report.totals.planned)} planned</span>
        <span>{currency.format(report.totals.pending)} pending</span>
      </div>
      <TransactionLedger
        title="Confirmed transaction ledger"
        transactions={report.transactions}
        emptyMessage="No confirmed transactions for this period yet."
        pageSize={8}
      />
    </div>
  )
}

function TransactionLedger({
  title,
  transactions,
  emptyMessage,
  pageSize = 8,
}: {
  title: string
  transactions: RecentTransaction[]
  emptyMessage: string
  pageSize?: number
}) {
  const [search, setSearch] = useState('')
  const [categoryFilter, setCategoryFilter] = useState('all')
  const [sortOrder, setSortOrder] = useState<'newest' | 'oldest' | 'amount_desc' | 'amount_asc' | 'merchant'>('newest')
  const [page, setPage] = useState(1)
  const categoryOptions = useMemo(() => {
    const names = new Set<string>()
    transactions.forEach((transaction) => transaction.categories.forEach((category) => names.add(category)))
    return Array.from(names).sort((a, b) => a.localeCompare(b))
  }, [transactions])
  const filteredTransactions = useMemo(() => {
    const query = search.trim().toLowerCase()
    return [...transactions]
      .filter((transaction) => categoryFilter === 'all' || transaction.categories.includes(categoryFilter))
      .filter((transaction) => {
        if (!query) return true

        const haystack = [
          transaction.merchant,
          transaction.categories.join(' '),
          transaction.occurred_on,
          formatShortDate(transaction.occurred_on),
          String(transaction.amount),
        ].join(' ').toLowerCase()
        return haystack.includes(query)
      })
      .sort((left, right) => sortTransactions(left, right, sortOrder))
  }, [categoryFilter, search, sortOrder, transactions])
  const totalPages = Math.max(1, Math.ceil(filteredTransactions.length / pageSize))
  const safePage = Math.min(page, totalPages)
  const pageStart = (safePage - 1) * pageSize
  const visibleTransactions = filteredTransactions.slice(pageStart, pageStart + pageSize)
  const filteredTotal = filteredTransactions.reduce((sum, transaction) => sum + transaction.amount, 0)

  return (
    <div className="recent-transaction-list transaction-ledger-list">
      <div className="transaction-ledger-heading">
        <div>
          <p className="eyebrow">{title}</p>
          {transactions.length > 0 && (
            <span>
              Showing {visibleTransactions.length === 0 ? 0 : pageStart + 1}–{pageStart + visibleTransactions.length} of {filteredTransactions.length} · {currency.format(filteredTotal)} selected
            </span>
          )}
        </div>
        {transactions.length > 0 && (
          <div className="transaction-ledger-controls" aria-label={`${title} filters`}>
            <label>
              <span className="sr-only">Search transactions</span>
              <input value={search} placeholder="Search merchant" onChange={(event) => { setSearch(event.currentTarget.value); setPage(1) }} />
            </label>
            <label>
              <span className="sr-only">Filter by category</span>
              <select value={categoryFilter} onChange={(event) => { setCategoryFilter(event.currentTarget.value); setPage(1) }}>
                <option value="all">All categories</option>
                {categoryOptions.map((category) => <option value={category} key={category}>{category}</option>)}
              </select>
            </label>
            <label>
              <span className="sr-only">Sort transactions</span>
              <select value={sortOrder} onChange={(event) => { setSortOrder(event.currentTarget.value as typeof sortOrder); setPage(1) }}>
                <option value="newest">Newest first</option>
                <option value="oldest">Oldest first</option>
                <option value="amount_desc">Amount high to low</option>
                <option value="amount_asc">Amount low to high</option>
                <option value="merchant">Merchant A to Z</option>
              </select>
            </label>
          </div>
        )}
      </div>
      {transactions.length === 0 ? (
        <p className="empty-ledger-copy">{emptyMessage}</p>
      ) : visibleTransactions.length === 0 ? (
        <p className="empty-ledger-copy">No confirmed transactions match those filters.</p>
      ) : visibleTransactions.map((transaction) => (
        <div className="recent-transaction-row" key={transaction.id}>
          <span>{formatShortDate(transaction.occurred_on)}</span>
          <strong>{transaction.merchant}</strong>
          <span>{transaction.categories.join(', ') || 'Uncategorized'}</span>
          <b>{currency.format(transaction.amount)}</b>
        </div>
      ))}
      {filteredTransactions.length > pageSize && (
        <div className="transaction-ledger-pagination" aria-label={`${title} pagination`}>
          <button type="button" className="secondary-button" disabled={safePage === 1} onClick={() => setPage((current) => Math.max(1, current - 1))}>Previous</button>
          <span>Page {safePage} of {totalPages}</span>
          <button type="button" className="secondary-button" disabled={safePage === totalPages} onClick={() => setPage((current) => Math.min(totalPages, current + 1))}>Next</button>
        </div>
      )}
    </div>
  )
}

function sortTransactions(left: RecentTransaction, right: RecentTransaction, sortOrder: 'newest' | 'oldest' | 'amount_desc' | 'amount_asc' | 'merchant') {
  switch (sortOrder) {
    case 'oldest':
      return left.occurred_on.localeCompare(right.occurred_on) || left.id - right.id
    case 'amount_desc':
      return right.amount - left.amount || right.occurred_on.localeCompare(left.occurred_on)
    case 'amount_asc':
      return left.amount - right.amount || right.occurred_on.localeCompare(left.occurred_on)
    case 'merchant':
      return left.merchant.localeCompare(right.merchant) || right.occurred_on.localeCompare(left.occurred_on)
    case 'newest':
    default:
      return right.occurred_on.localeCompare(left.occurred_on) || right.id - left.id
  }
}

function draftOccursInMonth(draft: TransactionDraft, month: BudgetMonth) {
  return draft.occurred_on >= month.starts_on && draft.occurred_on <= month.ends_on
}

function CategoryEditCell({
  row,
  draft,
  hasPendingDrafts,
  action,
  onChange,
  onArchive,
}: {
  row: BudgetCategoryRow
  draft: { name: string; stack_key: BudgetStackKey }
  hasPendingDrafts: boolean
  action: string | null
  onChange: (value: { name?: string; stack_key?: BudgetStackKey }) => void
  onArchive: () => void
}) {
  return (
    <div className="annual-category-cell-editor">
      <label>
        <span className="sr-only">Category name</span>
        <input value={draft.name} onChange={(event) => onChange({ name: event.currentTarget.value })} />
      </label>
      <label>
        <span className="sr-only">Expense stack</span>
        <select value={draft.stack_key} onChange={(event) => onChange({ stack_key: event.currentTarget.value as BudgetStackKey })}>
          <option value="non_discretionary">Non-discretionary</option>
          <option value="discretionary">Discretionary</option>
          <option value="sinking_expected">Sinking Fund — Expected</option>
          <option value="sinking_unexpected">Sinking Fund — Unexpected</option>
        </select>
      </label>
      <button
        type="button"
        className="archive-category-button"
        disabled={hasPendingDrafts || action === `archive-category:${row.id}`}
        title={hasPendingDrafts ? 'This category has pending drafts. Confirm, correct, or ignore those drafts before archiving.' : 'Archive this category'}
        onClick={onArchive}
      >
        {action === `archive-category:${row.id}` ? 'Archiving' : 'Archive'}
      </button>
      {hasPendingDrafts && <small>Pending drafts must be resolved before archiving.</small>}
    </div>
  )
}

function AnnualBudgetPlanner({
  plan,
  isRealWorkspace,
  action,
  error,
  selectedMonthIndex,
  spendingReport,
  spendingReportLoading,
  spendingReportError,
  newCategory,
  onNewCategoryChange,
  onCreateCategory,
  onBudgetViewChange,
  onSaveBudgetEdits,
  onArchiveCategory,
  onRestoreCategory,
  onApplyMiaActionDraft,
  onCancelMiaActionDraft,
  onUpdateDraft,
  onMatchDraft,
  onConfirmDraft,
  onIgnoreDraft,
  onReopenDraft,
}: {
  plan: AnnualBudgetPlan
  isRealWorkspace: boolean
  action: string | null
  error: string | null
  selectedMonthIndex: number
  spendingReport: SpendingReport | null
  spendingReportLoading: boolean
  spendingReportError: string | null
  newCategory: { name: string; stack_key: BudgetStackKey; monthly_amount: string }
  onNewCategoryChange: (value: { name: string; stack_key: BudgetStackKey; monthly_amount: string }) => void
  onCreateCategory: (event: FormEvent<HTMLFormElement>) => void
  onBudgetViewChange: (year: number, monthIndex: number) => void
  onSaveBudgetEdits: (changes: BudgetEditChanges) => Promise<void>
  onArchiveCategory: (row: BudgetCategoryRow) => void
  onRestoreCategory: (categoryId: number) => void
  onApplyMiaActionDraft: (draft: MiaActionDraft) => void
  onCancelMiaActionDraft: (draft: MiaActionDraft) => void
  onUpdateDraft: (draft: TransactionDraft, values: TransactionDraftUpdateInput) => Promise<void> | void
  onMatchDraft: (draft: TransactionDraft, matchId?: number) => void
  onConfirmDraft: (draft: TransactionDraft) => void
  onIgnoreDraft: (draft: TransactionDraft) => void
  onReopenDraft: (draft: TransactionDraft) => void
}) {
  const currentMonthIndex = Math.max(0, Math.min(plan.months.length - 1, selectedMonthIndex))
  const currentMonth = plan.months[currentMonthIndex]
  const currentMonthIncome = currentMonth ? plan.monthly_income[currentMonth.id] ?? 0 : 0
  const annualPlanned = plan.rows.reduce((sum, row) => sum + row.planned_total, 0)
  const annualActual = plan.rows.reduce((sum, row) => sum + row.actual_total, 0)
  const currentPlanned = plan.rows.reduce((sum, row) => sum + (row.months[currentMonthIndex]?.planned ?? 0), 0)
  const currentActual = plan.rows.reduce((sum, row) => sum + (row.months[currentMonthIndex]?.actual ?? 0), 0)
  const planSignature = useMemo(() => annualBudgetPlanSignature(plan), [plan])
  const [budgetEditState, setBudgetEditState] = useState<{
    signature: string
    isEditing: boolean
    allocationDrafts: Record<string, string>
    categoryDrafts: Record<string, { name: string; stack_key: BudgetStackKey }>
  }>({
    signature: planSignature,
    isEditing: false,
    allocationDrafts: {},
    categoryDrafts: {},
  })
  const allocationDrafts = useMemo(
    () => budgetEditState.signature === planSignature ? budgetEditState.allocationDrafts : {},
    [budgetEditState.allocationDrafts, budgetEditState.signature, planSignature],
  )
  const categoryDrafts = useMemo(
    () => budgetEditState.signature === planSignature ? budgetEditState.categoryDrafts : {},
    [budgetEditState.categoryDrafts, budgetEditState.signature, planSignature],
  )
  const isEditingBudget = budgetEditState.signature === planSignature && budgetEditState.isEditing
  const isSavingBudgetEdits = action === 'save-budget-edits'
  const editableBudget = isRealWorkspace && isEditingBudget && !isSavingBudgetEdits
  const allocationChanges = useMemo(() => budgetAllocationChanges(plan.rows, allocationDrafts), [allocationDrafts, plan.rows])
  const categoryChanges = useMemo(() => budgetCategoryChanges(plan.rows, categoryDrafts), [categoryDrafts, plan.rows])
  const totalBudgetChanges = allocationChanges.length + categoryChanges.length
  const archivedCategories = plan.archived_categories ?? []
  const today = new Date()
  const currentCalendarYear = today.getFullYear()
  const currentCalendarMonthIndex = today.getMonth()
  const isViewingCurrentYear = plan.year === currentCalendarYear
  const isViewingCurrentMonth = isViewingCurrentYear && currentMonthIndex === currentCalendarMonthIndex

  function beginBudgetEdit() {
    setBudgetEditState({ signature: planSignature, isEditing: true, allocationDrafts: {}, categoryDrafts: {} })
  }

  function cancelBudgetEdit() {
    setBudgetEditState({ signature: planSignature, isEditing: false, allocationDrafts: {}, categoryDrafts: {} })
  }

  async function saveBudgetEdits() {
    if (totalBudgetChanges === 0) {
      cancelBudgetEdit()
      return
    }

    await onSaveBudgetEdits({ allocations: allocationChanges, categories: categoryChanges })
  }

  function updateAllocationDraft(month: BudgetCategoryMonth, value: string) {
    setBudgetEditState((current) => ({
      signature: planSignature,
      isEditing: true,
      allocationDrafts: {
        ...(current.signature === planSignature ? current.allocationDrafts : {}),
        [allocationDraftKey(month)]: value,
      },
      categoryDrafts: current.signature === planSignature ? current.categoryDrafts : {},
    }))
  }

  function updateCategoryDraft(row: BudgetCategoryRow, value: { name?: string; stack_key?: BudgetStackKey }) {
    setBudgetEditState((current) => {
      const currentCategoryDrafts = current.signature === planSignature ? current.categoryDrafts : {}
      const existingDraft = categoryDraftValue(row, currentCategoryDrafts)

      return {
        signature: planSignature,
        isEditing: true,
        allocationDrafts: current.signature === planSignature ? current.allocationDrafts : {},
        categoryDrafts: {
          ...currentCategoryDrafts,
          [categoryDraftKey(row)]: { ...existingDraft, ...value },
        },
      }
    })
  }

  function renderBudgetEditActions() {
    if (!isRealWorkspace) return null

    return (
      <div className="annual-plan-edit-actions">
        {isEditingBudget ? (
          <>
            <button type="button" className="secondary-button" disabled={isSavingBudgetEdits} onClick={cancelBudgetEdit}>Cancel</button>
            <button type="button" disabled={isSavingBudgetEdits} onClick={() => void saveBudgetEdits()}>
              {isSavingBudgetEdits ? 'Saving' : totalBudgetChanges > 0 ? `Save ${totalBudgetChanges} change${totalBudgetChanges === 1 ? '' : 's'}` : 'Done'}
            </button>
          </>
        ) : (
          <button type="button" onClick={beginBudgetEdit}>Edit annual budget</button>
        )}
      </div>
    )
  }

  return (
    <article className="panel annual-budget-panel">
      <div className="annual-budget-heading">
        <div>
          <p className="eyebrow">Annual budget · {plan.year}</p>
          <h3>Year view with month-to-date truth</h3>
          <p>Plan the whole year, then let manual entries, receipts, and statements fill the actuals for each month.</p>
          <div className="budget-view-controls" aria-label="Budget report period controls">
            <button type="button" className="secondary-button" disabled={action === 'load-budget-year'} onClick={() => onBudgetViewChange(plan.year - 1, currentMonthIndex)}>Previous year</button>
            {!isViewingCurrentYear && (
              <button type="button" className="secondary-button current-period-button" disabled={action === 'load-budget-year'} onClick={() => onBudgetViewChange(currentCalendarYear, currentCalendarMonthIndex)}>This year</button>
            )}
            <label>
              <span className="sr-only">Report month</span>
              <select value={currentMonthIndex} onChange={(event) => onBudgetViewChange(plan.year, Number(event.currentTarget.value))}>
                {plan.months.map((month, index) => <option value={index} key={month.id}>{month.label}</option>)}
              </select>
            </label>
            {isViewingCurrentYear && !isViewingCurrentMonth && (
              <button type="button" className="secondary-button current-period-button" disabled={action === 'load-budget-year'} onClick={() => onBudgetViewChange(currentCalendarYear, currentCalendarMonthIndex)}>This month</button>
            )}
            <button type="button" className="secondary-button" disabled={action === 'load-budget-year'} onClick={() => onBudgetViewChange(plan.year + 1, currentMonthIndex)}>Next year</button>
          </div>
        </div>
        <div className="annual-budget-actions">
          <span>{plan.rows.length} categories</span>
          <span>{plan.pending_transaction_drafts.length} pending transaction drafts</span>
          {(plan.pending_mia_action_drafts ?? []).length > 0 && <span>{(plan.pending_mia_action_drafts ?? []).length} Mia action drafts</span>}
          {renderBudgetEditActions()}
        </div>
      </div>

      <div className="annual-budget-metrics">
        <Metric label={`${currentMonth?.label ?? 'Month'} income`} value={currency.format(currentMonthIncome)} />
        <Metric label={`${currentMonth?.label ?? 'Month'} planned`} value={currency.format(currentPlanned)} />
        <Metric label={`${currentMonth?.label ?? 'Month'} actual`} value={currency.format(currentActual)} />
        <Metric label="Annual planned" value={currency.format(annualPlanned)} />
        <Metric label="Annual actual" value={currency.format(annualActual)} />
      </div>

      {(plan.pending_mia_action_drafts ?? []).length > 0 && (
        <MiaActionDraftReviewStack
          drafts={plan.pending_mia_action_drafts ?? []}
          isRealWorkspace={isRealWorkspace}
          action={action}
          disabledReason={isEditingBudget ? 'Finish saving or canceling annual budget edits before applying Mia action drafts.' : undefined}
          draftActionsDisabled={isEditingBudget}
          onApply={onApplyMiaActionDraft}
          onCancel={onCancelMiaActionDraft}
        />
      )}

      {plan.pending_transaction_drafts.length > 0 && (
        <TransactionDraftReviewStack
          drafts={plan.pending_transaction_drafts}
          isRealWorkspace={isRealWorkspace}
          action={action}
          draftActionsDisabled={isEditingBudget}
          disabledReason={isEditingBudget ? 'Finish saving or canceling annual budget edits before confirming transaction drafts.' : undefined}
          categories={plan.rows}
          onUpdate={onUpdateDraft}
          onMatch={onMatchDraft}
          onConfirm={onConfirmDraft}
          onIgnore={onIgnoreDraft}
          onReopen={onReopenDraft}
        />
      )}

      <CurrentMonthActivityPanel
        plan={plan}
        currentMonthIndex={currentMonthIndex}
        spendingReport={spendingReport}
        loading={spendingReportLoading}
        error={spendingReportError}
      />

      <div className="annual-budget-editor-toolbar">
        <div>
          <p className="eyebrow">Annual plan editor</p>
          <strong>{isEditingBudget ? 'Editing is on' : 'Budget is read-only'}</strong>
          <span>{isEditingBudget ? 'Change monthly cells, rename categories, or add a new row below.' : 'Turn on editing when you want to change the annual plan.'}</span>
        </div>
        {renderBudgetEditActions()}
      </div>

      {isEditingBudget ? (
        <form className="annual-category-form" onSubmit={onCreateCategory}>
          <label>
            <span>New category</span>
            <input value={newCategory.name} placeholder="Groceries, Dining out, Travel" onChange={(event) => onNewCategoryChange({ ...newCategory, name: event.target.value })} disabled={!editableBudget} />
          </label>
          <label>
            <span>Stack</span>
            <select value={newCategory.stack_key} onChange={(event) => onNewCategoryChange({ ...newCategory, stack_key: event.target.value as BudgetStackKey })} disabled={!editableBudget}>
              <option value="non_discretionary">Non-discretionary</option>
              <option value="discretionary">Discretionary</option>
              <option value="sinking_expected">Sinking Fund — Expected</option>
              <option value="sinking_unexpected">Sinking Fund — Unexpected</option>
            </select>
          </label>
          <label>
            <span>Monthly plan</span>
            <input type="number" min="0" step="1" value={newCategory.monthly_amount} placeholder="0" onChange={(event) => onNewCategoryChange({ ...newCategory, monthly_amount: event.target.value })} disabled={!editableBudget} />
          </label>
          <button type="submit" disabled={!editableBudget || action === 'create-category'}>{action === 'create-category' ? 'Adding' : 'Add category'}</button>
        </form>
      ) : (
        <p className="annual-edit-hint">Click Edit annual budget to add categories or change monthly planned amounts.</p>
      )}

      {error && <p className="setup-error" role="alert">{error}</p>}

      <div className="annual-budget-table-wrap" role="region" aria-label="Annual budget table" tabIndex={0}>
        <table className="annual-budget-table">
          <thead>
            <tr>
              <th scope="col">Category</th>
              {plan.months.map((month, index) => (
                <th scope="col" className={index === currentMonthIndex ? 'current-month' : ''} key={month.id}>{month.label}</th>
              ))}
              <th scope="col">Year</th>
            </tr>
          </thead>
          <tbody>
            {plan.rows.length === 0 ? (
              <tr>
                <td colSpan={14}>Add a category to start building the annual plan.</td>
              </tr>
            ) : plan.rows.map((row) => (
              <tr key={row.id}>
                <th scope="row">
                  {editableBudget && row.active ? (
                    <CategoryEditCell
                      row={row}
                      draft={categoryDraftValue(row, categoryDrafts)}
                      hasPendingDrafts={plan.pending_transaction_drafts.some((draft) => draft.category_id === row.id)}
                      action={action}
                      onChange={(value) => updateCategoryDraft(row, value)}
                      onArchive={() => onArchiveCategory(row)}
                    />
                  ) : (
                    <>
                      <strong>{row.name}</strong>
                      <span>{row.stack_label}{row.active ? '' : ' · Archived'}</span>
                    </>
                  )}
                </th>
                {row.months.map((month, index) => {
                  const allocationMissing = !month.allocation_id || month.allocation_missing
                  const draftValue = allocationDraftValue(month, allocationDrafts)
                  const draftedAmount = Number(draftValue || 0)
                  const hasDraftChange = !allocationMissing && draftedAmount !== month.planned

                  return (
                    <td className={index === currentMonthIndex ? 'current-month' : ''} key={month.allocation_id ?? `missing-${month.period_id}`}>
                      {editableBudget && row.active && !allocationMissing ? (
                        <input
                          key={`${month.allocation_id ?? month.period_id}:${month.planned}`}
                          aria-label={`${row.name} planned for ${plan.months[index]?.label}`}
                          type="number"
                          min="0"
                          step="1"
                          value={draftValue}
                          data-dirty={hasDraftChange ? 'true' : undefined}
                          onChange={(event) => updateAllocationDraft(month, event.currentTarget.value)}
                        />
                      ) : (
                        <strong className="annual-planned-readonly">{currency.format(month.planned)}</strong>
                      )}
                      <small>{allocationMissing ? 'Allocation needs repair' : `${currency.format(month.actual)} actual`}</small>
                    </td>
                  )
                })}
                <td>
                  <strong>{currency.format(row.planned_total)}</strong>
                  <small>{currency.format(row.actual_total)} actual</small>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {archivedCategories.length > 0 && (
        <details className="archived-categories-panel">
          <summary>
            <span>Archived categories</span>
            <strong>{archivedCategories.length}</strong>
          </summary>
          <p>Archived categories leave active planning. Confirmed history stays visible in reports so past actuals do not disappear.</p>
          <div className="archived-category-list">
            {archivedCategories.map((category) => (
              <div className="archived-category-row" key={category.id}>
                <div>
                  <strong>{category.name}</strong>
                  <span>{category.stack_label}</span>
                </div>
                <button
                  type="button"
                  className="secondary-button"
                  disabled={!editableBudget || action === `restore-category:${category.id}`}
                  onClick={() => onRestoreCategory(category.id)}
                >
                  {action === `restore-category:${category.id}` ? 'Restoring' : 'Restore'}
                </button>
              </div>
            ))}
          </div>
          {!editableBudget && <small>Click Edit annual budget to restore archived categories.</small>}
        </details>
      )}

      {plan.recent_transactions.length > 0 && (
        <TransactionLedger
          title="Recent confirmed transactions"
          transactions={plan.recent_transactions}
          emptyMessage="No confirmed transactions for this budget year yet."
          pageSize={8}
        />
      )}
    </article>
  )
}

function loadStoredMiaMessages(storageKey: string) {
  try {
    const stored = window.localStorage.getItem(storageKey)
    if (!stored) return []

    const parsed = JSON.parse(stored) as MiaMessage[]
    if (!Array.isArray(parsed)) return []

    return parsed.filter((message) => (
      (message.role === 'assistant' || message.role === 'user')
      && typeof message.author === 'string'
      && typeof message.content === 'string'
      && message.content.trim().length > 0
    )).slice(-DEMO_MIA_STORAGE_MAX_MESSAGES)
  } catch {
    return []
  }
}

function saveStoredMiaMessages(storageKey: string, messages: MiaMessage[]) {
  try {
    if (messages.length === 0) {
      window.localStorage.removeItem(storageKey)
      return
    }

    const boundedMessages = messages.slice(-DEMO_MIA_STORAGE_MAX_MESSAGES)
    window.localStorage.setItem(storageKey, JSON.stringify(boundedMessages))
  } catch {
    // Ignore private browsing/storage quota issues. Chat still works in memory.
  }
}

function messageKey(message: MiaMessage, index: number) {
  return message.id ? `server-${message.id}` : message.client_id ?? `${message.author}-${index}`
}

function messageParagraphs(message: MiaMessage) {
  const speakerlessContent = message.role === 'assistant'
    ? message.content.replace(/^Mia:\s*/i, '')
    : message.content

  return speakerlessContent
    .replace(/\*\*(.*?)\*\*/g, '$1')
    .replace(/^\s*[-*]\s+/gm, '')
    .split(/\n{2,}/)
    .map((paragraph) => paragraph.trim())
    .filter(Boolean)
}

function MiaMark() {
  return (
    <svg viewBox="0 0 24 24" role="img" aria-label="Mia mark">
      <path d="M12 2.75 14.42 9.2l6.83 2.8-6.83 2.8L12 21.25 9.58 14.8 2.75 12l6.83-2.8L12 2.75Z" />
    </svg>
  )
}

function CohortIcon() {
  return (
    <svg viewBox="0 0 24 24" role="img" aria-label="Cohort">
      <path d="M4.5 6.5A2.5 2.5 0 0 1 7 4h10a2.5 2.5 0 0 1 2.5 2.5v11A2.5 2.5 0 0 1 17 20H7a2.5 2.5 0 0 1-2.5-2.5v-11Z" className="icon-stroke" />
      <path d="M8 9h8M8 12h5M8 15h7" className="icon-stroke" />
    </svg>
  )
}

function UsersIcon() {
  return (
    <svg viewBox="0 0 24 24" role="img" aria-label="Users">
      <path d="M9.2 11.1a3.1 3.1 0 1 0 0-6.2 3.1 3.1 0 0 0 0 6.2ZM4.4 19.1c.55-3.1 2.2-4.65 4.8-4.65 2.58 0 4.22 1.55 4.78 4.65" className="icon-stroke" />
      <path d="M16.2 11.4a2.55 2.55 0 1 0 0-5.1M15.7 14.45c2.05.18 3.35 1.58 3.9 4.2" className="icon-stroke" />
    </svg>
  )
}

function ShieldIcon() {
  return (
    <svg viewBox="0 0 24 24" role="img" aria-label="Secure access">
      <path d="M12 2.7 19 5.4v5.25c0 4.45-2.8 8.5-7 10.05-4.2-1.55-7-5.6-7-10.05V5.4l7-2.7Z" />
      <path d="m8.9 12.05 2 2 4.2-4.45" className="icon-stroke" />
    </svg>
  )
}

function SendIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M3.75 20.25 21 12 3.75 3.75v6.45L15.8 12 3.75 13.8v6.45Z" />
    </svg>
  )
}

function ExpandIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M8 4H4v4" className="icon-stroke" />
      <path d="M4 4l6 6" className="icon-stroke" />
      <path d="M16 20h4v-4" className="icon-stroke" />
      <path d="m20 20-6-6" className="icon-stroke" />
    </svg>
  )
}

function CollapseIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M10 4v6H4" className="icon-stroke" />
      <path d="M4 10 10 4" className="icon-stroke" />
      <path d="M14 20v-6h6" className="icon-stroke" />
      <path d="m20 14-6 6" className="icon-stroke" />
    </svg>
  )
}

function ScrollDownIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M12 5v13" className="icon-stroke" />
      <path d="m7 13 5 5 5-5" className="icon-stroke" />
    </svg>
  )
}

function CloseIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="m6.5 6.5 11 11M17.5 6.5l-11 11" className="icon-stroke" />
    </svg>
  )
}

function MicrophoneIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M12 4.25a3 3 0 0 1 3 3v4.25a3 3 0 0 1-6 0V7.25a3 3 0 0 1 3-3Z" className="icon-stroke" />
      <path d="M6.75 10.75v.75a5.25 5.25 0 0 0 10.5 0v-.75" className="icon-stroke" />
      <path d="M12 16.75v3" className="icon-stroke" />
      <path d="M9 19.75h6" className="icon-stroke" />
    </svg>
  )
}

function StopIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M8 8h8v8H8z" />
    </svg>
  )
}

function AttachmentIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M8 7.5h8M8 11.5h8M8 15.5h5" className="icon-stroke" />
      <path d="M6.5 3.5h8.25L18.5 7.25V20.5h-12v-17Z" className="icon-stroke" />
      <path d="M14.5 3.5v4h4" className="icon-stroke" />
    </svg>
  )
}

function StatementIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M5 7.25A2.25 2.25 0 0 1 7.25 5h9.5A2.25 2.25 0 0 1 19 7.25v9.5A2.25 2.25 0 0 1 16.75 19h-9.5A2.25 2.25 0 0 1 5 16.75v-9.5Z" className="icon-stroke" />
      <path d="M8 9.25h8M8 12h8M8 14.75h4.75" className="icon-stroke" />
    </svg>
  )
}

export default App
