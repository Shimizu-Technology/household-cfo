const currency = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' })
const wholeCurrency = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 })

export const formatReviewMoney = (cents: number) => (cents % 100 === 0 ? wholeCurrency : currency).format(cents / 100)
