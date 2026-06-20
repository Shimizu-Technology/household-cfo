module Demo
  class HouseholdData
    def self.profile
      {
        household: {
          name: "Household CFO Demo Family",
          stage: "Cohort preview",
          location: "Guam",
          primary_goal: "Build a clear monthly money rhythm before making a major career move"
        },
        coach: {
          name: "Mia",
          role: "Household CFO guide",
          voice: "warm, direct, practical"
        },
        members: [
          { name: "Ariana", role: "Primary household CFO", age_range: "30s" },
          { name: "Marcus", role: "Partner", age_range: "30s" }
        ],
        priorities: [
          "Know what is safe to spend",
          "Protect the emergency fund",
          "Plan a founder transition",
          "Reduce debt without losing momentum"
        ]
      }
    end

    def self.dashboard
      {
        summary: {
          monthly_income: 8250,
          fixed_expenses: 4625,
          flexible_spend: 1380,
          debt_payments: 920,
          savings_rate_percent: 14,
          runway_months: 4.6,
          next_safe_to_spend_amount: 540
        },
        accounts: [
          { name: "Checking", type: "cash", balance: 6840 },
          { name: "Emergency Fund", type: "savings", balance: 18250 },
          { name: "Credit Card", type: "debt", balance: -7350 },
          { name: "Auto Loan", type: "debt", balance: -11900 }
        ],
        alerts: [
          { tone: "green", title: "Bills covered", body: "All fixed expenses are funded through the next pay cycle." },
          { tone: "yellow", title: "Debt focus", body: "Card payoff is moving, but extra spending should stay below $540 this month." },
          { tone: "blue", title: "Runway", body: "You are 2.4 months away from the six-month founder transition target." }
        ]
      }
    end

    def self.optionality
      {
        scenario: "Founder transition",
        question: "What would it take to safely move from stable employment into the business full-time?",
        target_runway_months: 6,
        current_runway_months: 4.6,
        monthly_gap: 1350,
        choices: [
          {
            label: "Stay the course",
            readiness_score: 72,
            upside: "Lowest stress and keeps debt payoff consistent.",
            tradeoff: "Slower path to full-time founder mode."
          },
          {
            label: "Hybrid transition",
            readiness_score: 84,
            upside: "Protects household stability while opening 15 focused hours per week.",
            tradeoff: "Requires tighter discretionary spending for 90 days."
          },
          {
            label: "Leap now",
            readiness_score: 58,
            upside: "Maximum business focus immediately.",
            tradeoff: "Runway is short unless one new retainer is signed first."
          }
        ]
      }
    end

    def self.cfo_filter
      {
        framework: "CFO Filter",
        prompt: "Before money leaves the household, ask whether this spend protects stability, creates optionality, or moves the dream forward.",
        decisions: [
          {
            item: "Upgrade laptop",
            amount: 1800,
            recommendation: "Wait",
            reason: "Useful, but not required for the next 30-day revenue target. Revisit after one retainer closes."
          },
          {
            item: "Pay extra on credit card",
            amount: 500,
            recommendation: "Approve",
            reason: "Improves monthly breathing room and keeps the debt snowball moving."
          },
          {
            item: "Wednesday event visuals",
            amount: 250,
            recommendation: "Approve",
            reason: "Directly supports launch momentum and first-cohort demand generation."
          }
        ],
        targets: [
          { label: "Emergency fund", current: 18250, target: 24000 },
          { label: "Credit card payoff", current: 7350, target: 0 },
          { label: "Monthly business revenue", current: 3200, target: 6000 }
        ]
      }
    end

    def self.mia_messages
      {
        messages: [
          {
            role: "assistant",
            author: "Mia",
            content: "I’m looking at your cash flow, runway, and debt pressure together — not just one number in isolation."
          },
          {
            role: "user",
            author: "Ariana",
            content: "Can I start moving toward the business full-time?"
          },
          {
            role: "assistant",
            author: "Mia",
            content: "Yes, but the cleanest path is a hybrid transition. Close one more monthly retainer or add $5,750 to runway first."
          }
        ]
      }
    end
  end
end
