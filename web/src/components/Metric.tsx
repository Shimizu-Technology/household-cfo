export function Metric({ label, value }: { label: string; value: string }) {
  const lengthClass = value.length > 14 ? 'metric-value-xlong' : value.length > 10 ? 'metric-value-long' : ''

  return (
    <article className="metric-card">
      <span>{label}</span>
      <strong className={lengthClass} title={value}>{value}</strong>
    </article>
  )
}
