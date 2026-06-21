// ChatSuggestions.swift
// Centralized list of starter prompts and simple rotation logic.

import Foundation

struct ChatSuggestions {
    // 30+ concise, useful mobile-friendly prompts
    static let all: [String] = [
        "Summarize the latest news in 3 bullet points.",
        "Give me 3 healthy lunch ideas I can make fast.",
        "Explain this like I’m 12: how does a VPN work?",
        "Draft a polite email to reschedule a meeting.",
        "Help me plan a 3‑day trip to Tokyo on a budget.",
        "Create a 20‑minute full‑body workout with no equipment.",
        "What are 5 interview questions for a product manager?",
        "Turn this into a to‑do list: clean kitchen, pay rent, call mom.",
        "Write a short bio (2–3 sentences) for LinkedIn.",
        "Explain pros and cons of buying vs leasing a car.",
        "Brainstorm 5 app ideas for students.",
        "Rewrite this to be friendlier: ‘Your request was denied.’",
        "What’s a quick weeknight dinner using chicken and rice?",
        "Suggest study techniques for learning a new language.",
        "Create a packing checklist for a weekend hike.",
        "Explain the difference between RAM and storage simply.",
        "Give 3 tips to improve my sleep routine.",
        "How do I negotiate a salary increase—key points only.",
        "Draft an agenda for a 30‑minute team sync.",
        "Summarize the book ‘Atomic Habits’ in 5 bullets.",
        "What are 3 simple mindfulness exercises I can try today?",
        "Help me write a compelling app store description.",
        "Outline a 7‑day beginner running plan.",
        "Explain end‑to‑end encryption in simple terms.",
        "Turn this note into an organized outline: weekend trip to Paris.",
        "What’s a fast way to back up my iPhone photos?",
        "Write a friendly reminder to pay an overdue invoice.",
        "Give 5 icebreaker questions for a new team meeting.",
        "Suggest 3 ways to stay focused while studying.",
        "Translate this to Spanish and keep the tone casual: ‘See you soon!’",
        "Help me prioritize tasks for a busy day.",
        "Explain 2FA and why it matters in one paragraph.",
        "Create a grocery list for 3 easy dinners this week.",
        "How can I reduce phone distractions without missing important alerts?",
        "Suggest 3 warm‑up stretches before a run.",
        "Give an example of a SMART goal for fitness.",
        "Give me an interesting fact.",
        "Tell me a joke.",
        "Surprise me!",
        "Explain how LLMs work.",
        "What are the masses and volumes of the Earth and the Sun, and what is the distance between them?",
        "Act as a translator and translate all future prompts into the language I will specify.",
        "Write a poem about AI.",
        "Write a short story about a scientist.",
        "Who first used the digit “0”?",
        "List some of the most dangerous species.",
        "How to overcome procrastination?",
        "How did the Ancient Egyptians build the pyramids?",
        "Provide an overview of historical and contemporary indigenous communities and civilizations in the Americas.",
        "Give 5 wilderness survival tips.",
        "List 10 emergency response and first aid procedures for different scenarios like fires, earthquakes, heart attacks, car accidents, and drowning incidents.",
        "Give me a simple Python script with commentary.",
        "Provide information on the golden ratio and where it occurs in nature.",
        "List some highly efficient or otherwise unique human-powered vehicles like extreme bicycles and ornithopters.",
        "Let’s play a trivia game. Ask me 10 questions and offer 4 choices for each. If my answer is correct, proceed directly to the next question. If I give an incorrect answer, tell me the correct answer and explain why before moving on to the next question. Once I answer all 10 questions, tell me my score (correct vs. incorrect answers).",
        "How does wireless charging work, and is it good for the battery and the environment?",
        "Provide 5 battery health tips.",
        "Provide a short history of mobile phones from the earliest keypad cellphones to today’s touchscreen devices, and discuss possible future designs.",
        "Provide a brief history of the Internet.",
        "Provide a brief history of computers.",
        "Provide a brief history of AI.",
        "Describe the current scientific understanding of dark matter.",
        "Explain how quantum entanglement works.",
        "Describe the differences between quantum mechanics and general relativity.",
        "Explain why time dilation occurs.",
        "Explain the physics behind superconductors.",
        "Explain how CRISPR gene editing works.",
        "Explain how the immune system responds to infection.",
        "Explain how planets, stars, and black holes form and evolve.",
        "Describe the structure and properties of graphene.",
        "Explain the chemistry of batteries and energy storage.",
        "Discuss the challenges of carbon capture technologies.",
        "Compare different renewable energy technologies, and discuss why their adoption is slower than necessary.",
        "Explain how plate tectonics shapes the Earth’s surface.",
        "Discuss the prospects for human settlement on Mars.",
        "List some ancient tools and practices used in various fields like chemistry, medicine, and engineering that are still considered scientifically valid and effective (e.g., herbs, construction methods).",
        "List 10 inventions or discoveries commonly attributed to European scientists but actually achieved by Muslim scholars during the Islamic Golden Age.",
        "How was chess invented?",
        "How do slot machines and other gambling games ultimately profit their owners, even though players feel they can profit from them?",
        "How does addiction occur, and how can it be overcome?",
        "List 5 memorization techniques.",
        "Provide 5 cybersecurity tips to protect against data breaches, fraud, phishing, malware, and spyware.",
        "List 10 ways to protect my privacy (e.g., using ad blockers and VPNs, preferring local LLM inference apps like Noema instead of sharing data with large corporations).",
        "Create a step‑by‑step study plan for learning Python in 30 days.",
        "Proofread the following, point out any typos or grammatical errors, and rewrite a polished version.",
        "Summarize the attached document.",
        "Describe this image in detail.",
        "Help me break down a complex problem into smaller steps and solve it.",
        "Check the following code for bugs or possible improvements.",
        "Help me outline a sci‑fi novel.",
        "Explain quantum computing as if I’m 12 years old.",
        "Teach me the basics of linear algebra with examples.",
        "Give me 10 startup ideas in the healthcare industry.",
        "Help me brainstorm solutions to global climate change.",
        "Help me brainstorm unusual uses for a drone.",
        "Generate a list of innovative mobile app concepts.",
        "Give me an overview of the latest advances in fusion energy."
    ]

    private static let shuffledKey = "ChatSuggestions.Shuffled"
    private static let indexKey = "ChatSuggestions.Index"

    static func nextThree(datasetName: String?) -> [String] {
        guard let datasetName = sanitizedDatasetName(datasetName) else {
            return nextThree()
        }
        return [
            String.localizedStringWithFormat(
                String(localized: "Summarize %@ with citations."),
                datasetName
            ),
            String.localizedStringWithFormat(
                String(localized: "What are the most important open questions in %@?"),
                datasetName
            ),
            String.localizedStringWithFormat(
                String(localized: "Make a study guide from %@."),
                datasetName
            )
        ]
    }

    /// Returns 3 suggestions, rotating through a persisted shuffled list.
    /// When a full cycle completes, the list is reshuffled to keep it fresh.
    static func nextThree() -> [String] {
        let d = UserDefaults.standard
        var shuffled = d.stringArray(forKey: shuffledKey) ?? all.shuffled()
        if shuffled.count < 3 {
            shuffled = all.shuffled()
        }
        var idx = d.integer(forKey: indexKey)
        let n = shuffled.count

        func slice(from start: Int, count: Int) -> [String] {
            guard n > 0 else { return [] }
            return (0..<count).map { shuffled[(start + $0) % n] }
        }

        let needsReshuffle = (idx + 3) >= n
        let picks = slice(from: idx % n, count: 3)

        // Advance index and potentially reshuffle for the next call
        if needsReshuffle {
            shuffled = all.shuffled()
            d.set(shuffled, forKey: shuffledKey)
            idx = 0
        } else {
            idx = (idx + 3) % n
        }
        d.set(idx, forKey: indexKey)
        if d.stringArray(forKey: shuffledKey) == nil { d.set(shuffled, forKey: shuffledKey) }
        
        return picks
    }

    private static func sanitizedDatasetName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        if trimmed.count <= 48 {
            return trimmed
        }
        return String(trimmed.prefix(45)) + "..."
    }
}
