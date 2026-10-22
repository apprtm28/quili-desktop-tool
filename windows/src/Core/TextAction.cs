namespace Quili.Core
{
    /// <summary>
    /// What the server can be asked to do with text: the overlay's buttons act on the focused field, and the
    /// tray menu summarizes a chat thread read from another app's window.
    /// </summary>
    public enum TextAction
    {
        /// <summary>Rewrite in the same language, following the Paraphrase instruction from Settings.</summary>
        Paraphrase,

        /// <summary>Translate into natural, paraphrased English whatever the original language.</summary>
        TranslateToEnglish,

        /// <summary>Summarize the Slack thread that is open in the Slack window (never written back to a field).</summary>
        SummarizeThread,
    }

    public static class TextActionInfo
    {
        public static string Verb(this TextAction action) => action switch
        {
            TextAction.TranslateToEnglish => "Translate",
            TextAction.SummarizeThread => "Summarize",
            _ => "Paraphrase",
        };

        public static string Path(this TextAction action) => action switch
        {
            TextAction.TranslateToEnglish => "/api/translate",
            TextAction.SummarizeThread => "/api/summarize-thread",
            _ => "/api/paraphrase",
        };
    }
}
