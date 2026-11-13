// Workspace-wide styles load with the entry (in their original order) so the
// signed-out landing is styled without downloading the workspace bundle.
import './App.css'
import './styles/shell.css'
import './styles/cards.css'
import './styles/home.css'
import './styles/mia.css'
import './styles/charts.css'
import './styles/motion.css'

// Primitives and scoped native-control overrides follow legacy screen styles.
// ID specificity keeps these stable when component CSS loads in a lazy chunk.
import './styles/ui.css'
