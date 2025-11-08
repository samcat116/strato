import Elementary
import ElementaryHTMX

struct OnboardingSuccessMessage: HTML {
    let organizationName: String

    var content: some HTML {
        div(.class("text-center")) {
            div(.class("bg-green-100 border border-green-400 text-green-700 px-4 py-3 rounded mb-4")) {
                strong { "Success!" }
                " Your organization \"\(organizationName)\" has been created."
            }
            p(.class("text-gray-600 mb-4")) { "Redirecting to your dashboard..." }
            div(.class("animate-spin rounded-full h-8 w-8 border-b-2 border-indigo-600 mx-auto")) {}
        }
    }
}
