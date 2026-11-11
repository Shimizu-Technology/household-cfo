import type { CurrentUser } from '../api'
import type { AdminSection } from '../lib/appRoutes'
import { CoachStudio } from '../components/CoachStudio'
import { GroupsSection } from './sections/GroupsSection'
import { PeopleSection } from './sections/PeopleSection'
import { ReportsSection } from './sections/ReportsSection'
import { SettingsSection } from './sections/SettingsSection'
import { SupportSection } from './sections/SupportSection'
import { TodaySection } from './sections/TodaySection'

type Props = { section: AdminSection; currentUser: CurrentUser; onDirtyChange: (dirty: boolean) => void }

// One file per section under ./sections. The shell decides where each lives; each section owns what is in it.
export function AdminSectionContent({ section, currentUser, onDirtyChange }: Props) {
  switch (section.key) {
    case 'today': return <TodaySection currentUser={currentUser} />
    case 'people': return <PeopleSection currentUser={currentUser} />
    case 'groups': return <GroupsSection currentUser={currentUser} onDirtyChange={onDirtyChange} />
    case 'coaching': return <CoachStudio currentUser={currentUser} onDirtyChange={onDirtyChange} />
    case 'reports': return <ReportsSection currentUser={currentUser} />
    case 'support': return <SupportSection currentUser={currentUser} />
    case 'settings': return <SettingsSection currentUser={currentUser} onDirtyChange={onDirtyChange} />
  }
}
