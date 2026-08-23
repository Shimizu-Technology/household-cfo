export function Metric({ label, value, detail, className = '' }: { label: string; value: string; detail?: string; className?: string }) {
  const lengthClass = value.length > 14 ? 'metric-value-xlong' : value.length > 10 ? 'metric-value-long' : ''

  return (
    <article className={`metric-card${className ? ` ${className}` : ''}`}>
      <span>{label}</span>
      <strong className={lengthClass} title={value}>{value}</strong>
      {detail && <small>{detail}</small>}
    </article>
  )
}
