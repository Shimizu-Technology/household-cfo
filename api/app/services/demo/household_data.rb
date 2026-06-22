module Demo
  class HouseholdData
    def self.persona
      @persona ||= ::Mia::Persona.default
    end

    def self.profile
      {
        household: {
          name: "Household CFO Demo Family",
          stage: "Cohort preview",
          location: "Guam",
          primary_goal: "Build a clear monthly money rhythm before making a major career move"
        },
        coach: {
          name: persona.name,
          role: persona.role,
          voice: persona.voice_summary
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
        ],
        completeness: 68,
        uploads: [
          { label: "Upload spreadsheet", kind: "spreadsheet", status: "Optional starter import", accepts: ".xlsx, .xls, .csv" },
          { label: "Upload statement", kind: "statement", status: "Bank or credit card PDF/CSV", accepts: ".pdf, .csv, .png, .jpg" },
          { label: "Upload pay stub", kind: "paystub", status: "Photo or PDF when ready", accepts: ".pdf, .png, .jpg" }
        ],
        sections: [
          {
            label: "Income",
            summary: "Base pay, rental income, bonuses, and business revenue.",
            items: [
              { label: "Primary income", amount: 5200 },
              { label: "Rental/passive income", amount: 1850 },
              { label: "Business income", amount: 1200 }
            ]
          },
          {
            label: "Expenses",
            summary: "Bills, choices, and the things life always seems to throw at you.",
            items: [
              { label: "Housing", amount: 2100 },
              { label: "Fixed bills", amount: 2525 },
              { label: "Food, gas, discretionary", amount: 1380 }
            ]
          },
          {
            label: "Savings & Debt",
            summary: "Runway, credit cards, loans, and the next stability target.",
            items: [
              { label: "Emergency fund", amount: 18250 },
              { label: "Credit card debt", amount: -7350 },
              { label: "Auto loan", amount: -11900 }
            ]
          }
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
          next_safe_to_spend_amount: 540,
          readiness_label: "Yellow — close, but protect runway"
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
        ],
        next_steps: [
          "Keep this month’s flexible spending under $1,380.",
          "Move $500 extra toward the credit card after fixed bills clear.",
          "Add one recurring business retainer before changing job income."
        ]
      }
    end

    def self.budget
      {
        framework: "Expense Stack",
        intro: "Most budgets collapse life into bills versus fun. Household CFO separates the expenses that surprise you before they turn into emergencies.",
        monthly_income: 8250,
        total_monthly_outflow: 6925,
        baseline_surplus: 1325,
        stacks: [
          {
            label: "Non-discretionary",
            color: "green",
            amount: 4625,
            description: "Fixed, non-negotiable monthly obligations.",
            examples: [ "Mortgage/rent", "utilities", "insurance", "loan minimums" ]
          },
          {
            label: "Discretionary",
            color: "yellow",
            amount: 1380,
            description: "Choices that still matter, but can be shaped.",
            examples: [ "groceries", "coffee", "eating out", "subscriptions" ]
          },
          {
            label: "Sinking Fund — Expected",
            color: "gold",
            amount: 560,
            description: "Known irregular expenses that should stop feeling like surprises.",
            examples: [ "car registration", "back to school", "holidays" ]
          },
          {
            label: "Sinking Fund — Unexpected",
            color: "red",
            amount: 360,
            description: "Life-happens money for repairs, medical, and family support.",
            examples: [ "car repair", "clinic visit", "appliance replacement" ]
          }
        ],
        custom_categories_note: "Defaults are a starting point. Users should be able to rename categories into the language of their household."
      }
    end

    def self.wealth
      {
        summary: {
          net_worth: 142_800,
          liquid_net_worth: 25_090,
          retirement_projection: 418_000,
          monthly_wealth_building: 900
        },
        milestones: [
          { label: "Six-month runway", current: 4.6, target: 6, unit: "months", status: "yellow" },
          { label: "Credit card paid off", current: 2650, target: 7350, unit: "dollars paid", status: "yellow" },
          { label: "Founder transition reserve", current: 18_250, target: 24_000, unit: "dollars", status: "green" }
        ],
        guidance: "Wealth here is not about looking rich. It is about buying back options, lowering panic, and making the next right move visible."
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
        ],
        levers: [
          { label: "Business needs to pay", amount: 2122 },
          { label: "Partner/filler income", amount: 2800 },
          { label: "Runway gap", amount: 5750 }
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
        ],
        priority_stack: [ "Protect the roof", "Protect food/gas", "Protect runway", "Attack high-interest debt", "Fund the dream with evidence" ]
      }
    end

    def self.mia_messages
      {
        messages: [
          {
            role: "assistant",
            author: "Mia",
            content: "Håfa Adai. I loaded your profile, your Expense Stack, and your runway so we can look at the whole picture, not one scary number by itself."
          },
          {
            role: "user",
            author: "Ariana",
            content: "Can I start moving toward the business full-time?"
          },
          {
            role: "assistant",
            author: "Mia",
            content: "You can move toward it, but the clean path is hybrid first. Your runway is strong enough to plan, not strong enough to gamble. One next move: close one more monthly retainer or add $5,750 to runway before you cut stable income."
          }
        ],
        quick_prompts: [
          "Why is my baseline yellow?",
          "Can I leave my job?",
          "Emergency fund or debt first?",
          "What should I do with a bonus?"
        ],
        disclaimer: persona.disclaimer
      }
    end
  end
end
