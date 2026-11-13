// Controls that accept typed text and can summon the phone keyboard.
// Shared by shell focus detection and its pointer hold; native pickers stay out.
export const TEXT_ENTRY_SELECTOR = 'input:not([type]), input:is([type="text"], [type="search"], [type="email"], [type="url"], [type="tel"], [type="password"], [type="number"]), textarea, [contenteditable="true"]'
