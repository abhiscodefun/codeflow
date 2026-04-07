const fs = require('fs');

const dartFilePath = "c:\\Users\\abhi0\\OneDrive\\Desktop\\vs\\vs\\lib\\main.dart";
const jsFilePath = "c:\\Users\\abhi0\\OneDrive\\Desktop\\vs\\vs\\backend\\server.js";
const outputFilePath = "c:\\Users\\abhi0\\OneDrive\\Desktop\\vs\\vs\\project_code_appendix_formatted.md";

try {
    let dartCode = fs.readFileSync(dartFilePath, 'utf8');
    let jsCode = fs.readFileSync(jsFilePath, 'utf8');

    function insertHeader(text, searchStr, headerText) {
        const banner = '\n\n\n\n' +
            '// ============================================================================\n' +
            '// ============================================================================\n' +
            '// SECTION: ' + headerText + '\n' +
            '// ============================================================================\n' +
            '// ============================================================================\n\n';
        return text.replace(searchStr, banner + searchStr);
    }

    // 1. Break Dart UI / State into sections
    dartCode = insertHeader(dartCode, "Future<void> main() async {", "APP INITIALIZATION & CONFIGURATION");
    dartCode = insertHeader(dartCode, "class MyApp extends StatelessWidget {", "MAIN APPLICATION ROOT");
    dartCode = insertHeader(dartCode, "class SketchPreviewScreen ", "MAIN WORKSPACE SCREEN (STATEFUL WIDGET)");
    dartCode = insertHeader(dartCode, "class _SketchPreviewScreenState ", "WORKSPACE STATE MANAGEMENT & VARIABLES");
    dartCode = insertHeader(dartCode, "Future<String> _callGemini(", "AI INTEGRATION: GEMINI API COMMUNICATION PIPELINE");
    dartCode = insertHeader(dartCode, "void _generatePreview({String? userReply}) async {", "AI INTEGRATION: SKETCH ANALYSIS & PREVIEW GENERATION TRIGGER");
    dartCode = insertHeader(dartCode, "Future<void> _pickImage() async {", "UTILITY: IMAGE PICKER & SUPABASE UPLOAD");
    dartCode = insertHeader(dartCode, "Widget build(BuildContext context) {", "CORE UI ROUTING: MAIN DASHBOARD LAYOUT & CANVAS");
    dartCode = insertHeader(dartCode, "Widget _buildSidebar() {", "UI COMPONENT: LEFT SIDEBAR CONTROLS");
    dartCode = insertHeader(dartCode, "Widget _buildAIPopup() {", "UI COMPONENT: AI CLARIFICATION INTERACTIVE POP-UP");
    dartCode = insertHeader(dartCode, "Widget _buildPhoneMockup() {", "UI COMPONENT: DEVICE PREVIEW FRAME");
    dartCode = insertHeader(dartCode, "Widget _buildPrunePopup() {", "UI COMPONENT: ELEMENT PRUNING/EDITING MODAL");

    // 2. Format JS Code
    jsCode = insertHeader(jsCode, "const express = require('express');", "BACKEND: SERVER SETUP & DEPENDENCIES");
    jsCode = insertHeader(jsCode, "app.post('/api/generate', async (req, res)", "BACKEND: GEMINI API GENERATION ENDPOINT");

    // 3. Assemble the final Markdown document
    let markdownOutput = '# Source Code Appendix\n\n' +
        'This appendix contains the core application code, divided into logical sections highlighting configuration, state management, core AI generation logic, UI components, and the backend Express server.\n\n' +
        '## Part 1: Frontend Application (Flutter/Dart)\n' +
        '```dart\n' + dartCode + '\n```\n\n' +
        '## Part 2: Generative API Server (Node.js/Express)\n' +
        '```javascript\n' + jsCode + '\n```\n';

    fs.writeFileSync(outputFilePath, markdownOutput);
    console.log("Successfully generated project_code_appendix_formatted.md");
} catch(e) {
    console.error("Error running script:", e);
}
