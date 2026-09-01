import type { ButtonHTMLAttributes, ReactNode } from 'react'

type ButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
  children: ReactNode
  size?: 'compact' | 'default'
  variant?: 'primary' | 'secondary' | 'ghost' | 'danger'
}

export function Button({
  children,
  className = '',
  size = 'default',
  type = 'button',
  variant = 'primary',
  ...props
}: ButtonProps) {
  const classes = ['button', `button--${variant}`, `button--${size}`, className]
    .filter(Boolean)
    .join(' ')

  return (
    <button type={type} className={classes} {...props}>
      {children}
    </button>
  )
}
