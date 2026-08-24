export function moneyCents(value: number) {
  return Math.round(value * 100)
}

export function dollarsFromCents(cents: number) {
  return cents / 100
}

export function addMoney(...values: number[]) {
  return dollarsFromCents(values.reduce((total, value) => total + moneyCents(value), 0))
}

export function subtractMoney(minuend: number, ...subtrahends: number[]) {
  return dollarsFromCents(
    moneyCents(minuend) - subtrahends.reduce((total, value) => total + moneyCents(value), 0),
  )
}

export function sumMoney(values: Iterable<number>) {
  let cents = 0
  for (const value of values) cents += moneyCents(value)
  return dollarsFromCents(cents)
}

export function multiplyMoney(value: number, multiplier: number) {
  return dollarsFromCents(moneyCents(value) * multiplier)
}
