/**
 * DOTBOT Control Panel - Markdown Parser
 * Markdown to HTML conversion utilities
 */

/**
 * Format cell content with inline code support
 * @param {string} text - Cell text
 * @returns {string} Formatted HTML
 */
function formatCellContent(text) {
    // Extract code spans into placeholders, then escape, then apply bold/italic, then restore
    const codePlaceholders = [];
    let processed = text.replace(/`([^`]+)`/g, (_, code) => {
        const idx = codePlaceholders.length;
        codePlaceholders.push(`<code class="inline">${escapeHtml(code)}</code>`);
        return `\x00CODE${idx}\x00`;
    });

    // Links [text](url) - extract before escaping to preserve raw URLs
    const linkPlaceholders = [];
    processed = processed.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_, linkText, url) => {
        const idx = linkPlaceholders.length;
        linkPlaceholders.push(`<a href="${escapeHtml(url)}" target="_blank" rel="noopener noreferrer">${escapeHtml(linkText)}</a>`);
        return `\x00LINK${idx}\x00`;
    });

    // Escape HTML on the non-code parts
    processed = escapeHtml(processed);

    // Bold (**text**) then italic (*text*) - non-greedy
    processed = processed.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
    processed = processed.replace(/\*(.+?)\*/g, '<em>$1</em>');

    // Restore code placeholders
    processed = processed.replace(/\x00CODE(\d+)\x00/g, (_, idx) => codePlaceholders[parseInt(idx)]);

    // Restore link placeholders
    processed = processed.replace(/\x00LINK(\d+)\x00/g, (_, idx) => linkPlaceholders[parseInt(idx)]);

    return processed;
}

/**
 * Parse markdown table to HTML
 * @param {string[]} tableLines - Array of table lines
 * @returns {string|null} HTML table or null if invalid
 */
function parseMarkdownTable(tableLines) {
    if (tableLines.length < 2) return null;

    // Parse header row
    const headerCells = tableLines[0]
        .split('|')
        .map(cell => cell.trim())
        .filter(cell => cell !== '');

    // Parse separator row for alignment
    const separatorCells = tableLines[1]
        .split('|')
        .map(cell => cell.trim())
        .filter(cell => cell !== '');

    // Validate separator row (must contain dashes)
    if (!separatorCells.every(cell => /^:?-+:?$/.test(cell))) {
        return null;
    }

    // Determine alignment for each column
    const alignments = separatorCells.map(cell => {
        const left = cell.startsWith(':');
        const right = cell.endsWith(':');
        if (left && right) return 'center';
        if (right) return 'right';
        return 'left';
    });

    // Build HTML
    let html = '<div class="table-wrapper"><table>';

    // Header
    html += '<thead><tr>';
    headerCells.forEach((cell, i) => {
        const align = alignments[i] || 'left';
        html += `<th style="text-align: ${align}">${formatCellContent(cell)}</th>`;
    });
    html += '</tr></thead>';

    // Body rows
    html += '<tbody>';
    for (let i = 2; i < tableLines.length; i++) {
        const cells = tableLines[i]
            .split('|')
            .map(cell => cell.trim())
            .filter(cell => cell !== '');

        if (cells.length === 0) continue;

        html += '<tr>';
        cells.forEach((cell, j) => {
            const align = alignments[j] || 'left';
            html += `<td style="text-align: ${align}">${formatCellContent(cell)}</td>`;
        });
        html += '</tr>';
    }
    html += '</tbody>';

    html += '</table></div>';
    return html;
}

/**
 * Parse fenced code block to HTML
 * @param {string[]} codeLines - Array of code lines
 * @param {string} language - Language identifier
 * @returns {string} HTML code block
 */
function parseCodeBlock(codeLines, language) {
    const code = codeLines.join('\n');
    const langLabel = language ? `<div class="code-lang">${escapeHtml(language)}</div>` : '';
    return `<div class="code-block">${langLabel}<pre><code>${escapeHtml(code)}</code></pre></div>`;
}

/**
 * Parse Mermaid diagram block to HTML
 * Creates a container with loading state, hidden syntax, and fallback
 * @param {string[]} codeLines - Array of mermaid syntax lines
 * @returns {string} HTML mermaid container
 */
function parseMermaidBlock(codeLines) {
    const code = codeLines.join('\n');
    const escapedCode = escapeHtml(code);

    return `<div class="mermaid-container" data-pending="true">
        <div class="mermaid-label">Diagram</div>
        <div class="mermaid-loading">Rendering diagram...</div>
        <div class="mermaid-rendered" style="display: none;"></div>
        <pre class="mermaid-syntax" style="display: none;">${escapedCode}</pre>
        <div class="mermaid-fallback" style="display: none;"><pre>${escapedCode}</pre></div>
    </div>`;
}

/**
 * Helper to group consecutive list items into proper list tags
 * @param {string} html - HTML with list placeholders
 * @param {string} placeholderType - Type of placeholder (ULI or OLI)
 * @param {string} listTag - HTML list tag (ul or ol)
 * @returns {string} HTML with proper list tags
 */
function groupListItems(html, placeholderType, listTag) {
    const startMarker = `___${placeholderType}_START___`;
    const endMarker = `___${placeholderType}_END___`;

    // Split into lines for processing
    const lines = html.split('\n');
    const result = [];
    let inList = false;

    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        const hasListItem = line.includes(startMarker) && line.includes(endMarker);

        if (hasListItem) {
            // Convert placeholder to <li>
            const convertedLine = line.replace(
                new RegExp(`${startMarker}(.+?)${endMarker}`, 'g'),
                '<li>$1</li>'
            );

            if (!inList) {
                // Start a new list
                result.push(`<${listTag}>`);
                inList = true;
            }
            result.push(convertedLine);
        } else {
            if (inList) {
                // Look ahead past blank lines to see if another list item follows
                let nextNonEmpty = null;
                for (let j = i + 1; j < lines.length; j++) {
                    if (lines[j].trim() !== '') {
                        nextNonEmpty = lines[j];
                        break;
                    }
                }
                if (nextNonEmpty && nextNonEmpty.includes(startMarker) && nextNonEmpty.includes(endMarker)) {
                    // Another list item follows — keep the list open, skip the blank line
                    continue;
                }
                // Non-list content follows — close the list
                result.push(`</${listTag}>`);
                inList = false;
            }
            result.push(line);
        }
    }

    // Close any unclosed list at the end
    if (inList) {
        result.push(`</${listTag}>`);
    }

    return result.join('\n');
}

/**
 * Check if content looks like valid YAML frontmatter
 * Must have at least one "key: value" line where key has no spaces
 * @param {string} content - Potential frontmatter content
 * @returns {boolean} True if looks like YAML
 */
function looksLikeYaml(content) {
    const lines = content.split('\n').filter(line => line.trim());
    // Must have at least one proper key: value pair
    return lines.some(line => {
        const colonIndex = line.indexOf(':');
        if (colonIndex <= 0) return false;
        const key = line.substring(0, colonIndex).trim();
        // Key should be a simple identifier (no spaces, starts with letter)
        return /^[a-zA-Z_][a-zA-Z0-9_-]*$/.test(key);
    });
}

/**
 * Parse YAML frontmatter to HTML
 * @param {string} frontmatter - YAML frontmatter content (without delimiters)
 * @returns {string} HTML formatted frontmatter
 */
function parseFrontmatter(frontmatter) {
    const lines = frontmatter.split('\n').filter(line => line.trim());
    if (lines.length === 0) return '';

    let html = '<div class="frontmatter">';
    html += '<div class="frontmatter-title" onclick="this.parentElement.classList.toggle(\'expanded\')" role="button" tabindex="0">Metadata <span class="frontmatter-toggle">&#9654;</span></div>';
    html += '<table class="frontmatter-table">';

    for (const line of lines) {
        const colonIndex = line.indexOf(':');
        if (colonIndex > 0) {
            const key = line.substring(0, colonIndex).trim();
            let value = line.substring(colonIndex + 1).trim();

            // Strip outer quotes from values
            if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
                value = value.slice(1, -1);
            }

            // Format arrays nicely
            if (value.startsWith('[') && value.endsWith(']')) {
                const items = value.slice(1, -1).split(',').map(s => s.trim().replace(/^["']|["']$/g, ''));
                const tagsHtml = items.map(item => `<span class="frontmatter-tag">${escapeHtml(item)}</span>`).join(' ');
                html += `<tr><td class="frontmatter-key">${escapeHtml(key)}</td><td class="frontmatter-value">${tagsHtml}</td></tr>`;
            } else {
                html += `<tr><td class="frontmatter-key">${escapeHtml(key)}</td><td class="frontmatter-value">${escapeHtml(value)}</td></tr>`;
            }
        }
    }

    html += '</table></div>';
    return html;
}

/**
 * Convert markdown to HTML
 * @param {string} markdown - Markdown text
 * @returns {string} HTML
 */
function markdownToHtml(markdown) {
    if (!markdown) return '';

    // Normalize line endings (Windows CRLF -> Unix LF)
    markdown = markdown.replace(/\r\n/g, '\n').replace(/\r/g, '\n');

    // Handle YAML frontmatter (must be at very start of document)
    let frontmatterHtml = '';
    if (markdown.startsWith('---\n')) {
        const endIndex = markdown.indexOf('\n---\n', 4);
        if (endIndex !== -1) {
            const frontmatter = markdown.substring(4, endIndex);
            // Only treat as frontmatter if it looks like valid YAML
            if (looksLikeYaml(frontmatter)) {
                frontmatterHtml = parseFrontmatter(frontmatter);
                markdown = markdown.substring(endIndex + 5); // Skip past closing ---\n
            }
        } else if (markdown.indexOf('\n---', 4) === markdown.lastIndexOf('\n---')) {
            // Frontmatter at end of file (no trailing newline after ---)
            const altEndIndex = markdown.indexOf('\n---', 4);
            if (altEndIndex !== -1 && altEndIndex + 4 >= markdown.length) {
                const frontmatter = markdown.substring(4, altEndIndex);
                if (looksLikeYaml(frontmatter)) {
                    frontmatterHtml = parseFrontmatter(frontmatter);
                    markdown = '';
                }
            }
        }
    }

    // First pass: parse tables and code blocks before escaping
    const lines = markdown.split('\n');
    const processedLines = [];
    const placeholders = {};
    let placeholderCount = 0;
    let i = 0;

    while (i < lines.length) {
        const line = lines[i];

        // Check if this is the start of a fenced code block (may be indented)
        const codeBlockMatch = line.match(/^(\s*)```(\w*)\s*$/);
        if (codeBlockMatch) {
            const indent = codeBlockMatch[1] || '';
            const language = codeBlockMatch[2] || '';
            const codeLines = [];
            i++; // Skip opening fence

            // Collect lines until closing fence (with same or less indentation)
            while (i < lines.length && !lines[i].match(/^\s*```\s*$/)) {
                // Remove the indent prefix from code lines if present
                let codeLine = lines[i];
                if (indent && codeLine.startsWith(indent)) {
                    codeLine = codeLine.substring(indent.length);
                }
                codeLines.push(codeLine);
                i++;
            }
            i++; // Skip closing fence

            // Create placeholder - use mermaid parser for mermaid blocks
            const placeholder = `___CODE_PLACEHOLDER_${placeholderCount}___`;
            if (language.toLowerCase() === 'mermaid') {
                placeholders[placeholder] = parseMermaidBlock(codeLines);
            } else {
                placeholders[placeholder] = parseCodeBlock(codeLines, language);
            }
            processedLines.push(placeholder);
            placeholderCount++;
            continue;
        }

        // Check if this looks like the start of a table
        if (line.trim().startsWith('|') && line.trim().endsWith('|')) {
            // Collect consecutive table lines
            const tableLines = [];
            while (i < lines.length && lines[i].trim().startsWith('|')) {
                tableLines.push(lines[i]);
                i++;
            }

            // Try to parse as table
            const tableHtml = parseMarkdownTable(tableLines);
            if (tableHtml) {
                const placeholder = `___TABLE_PLACEHOLDER_${placeholderCount}___`;
                placeholders[placeholder] = tableHtml;
                processedLines.push(placeholder);
                placeholderCount++;
            } else {
                // Not a valid table, add lines back
                tableLines.forEach(tl => processedLines.push(tl));
            }
            continue;
        }

        processedLines.push(line);
        i++;
    }

    // Process inline code before escaping (need raw backticks)
    let text = processedLines.join('\n');

    // Replace inline code with placeholders
    text = text.replace(/`([^`]+)`/g, (match, code) => {
        const placeholder = `___INLINE_CODE_${placeholderCount}___`;
        placeholders[placeholder] = `<code class="inline">${escapeHtml(code)}</code>`;
        placeholderCount++;
        return placeholder;
    });

    // Apply markdown transformations BEFORE escaping (while placeholders protect code blocks)
    // Horizontal rules (document separators)
    text = text.replace(/^---$/gm, '___HR_PLACEHOLDER___');

    // Headers - only process lines that aren't placeholders
    // Process from most specific (####) to least specific (#) to avoid conflicts
    text = text.replace(/^#### (.+)$/gm, (match, p1) => {
        if (p1.includes('___') && p1.includes('_PLACEHOLDER_')) return match;
        return `___H4_START___${p1}___H4_END___`;
    });
    text = text.replace(/^### (.+)$/gm, (match, p1) => {
        if (p1.includes('___') && p1.includes('_PLACEHOLDER_')) return match;
        return `___H3_START___${p1}___H3_END___`;
    });
    text = text.replace(/^## (.+)$/gm, (match, p1) => {
        if (p1.includes('___') && p1.includes('_PLACEHOLDER_')) return match;
        return `___H2_START___${p1}___H2_END___`;
    });
    text = text.replace(/^# (.+)$/gm, (match, p1) => {
        if (p1.includes('___') && p1.includes('_PLACEHOLDER_')) return match;
        return `___H1_START___${p1}___H1_END___`;
    });

    // Bold and italic
    text = text.replace(/\*\*(.+?)\*\*/g, '___BOLD_START___$1___BOLD_END___');
    text = text.replace(/\*(.+?)\*/g, '___ITALIC_START___$1___ITALIC_END___');

    // Links [text](url)
    text = text.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (match, linkText, url) => {
        const placeholder = `___LINK_PLACEHOLDER_${placeholderCount}___`;
        placeholders[placeholder] = `<a href="${escapeHtml(url)}" target="_blank" rel="noopener noreferrer">${escapeHtml(linkText)}</a>`;
        placeholderCount++;
        return placeholder;
    });

    // Lists - unordered (- item)
    text = text.replace(/^- (.+)$/gm, '___ULI_START___$1___ULI_END___');

    // Lists - ordered: First split inline numbered lists (e.g., "1. First 2. Second" -> separate lines)
    // Insert newline before " 2. ", " 3. ", etc. (but not " 1. " to avoid breaking start of list)
    text = text.replace(/ (\d+)\. /g, (match, num) => {
        return parseInt(num) > 1 ? `\n${num}. ` : match;
    });

    // Now convert ordered list items (1. item, 2. item, etc.)
    text = text.replace(/^\d+\.\s+(.+)$/gm, '___OLI_START___$1___OLI_END___');

    // Now escape HTML
    let html = escapeHtml(text);

    // Restore markdown element placeholders
    html = html.replace(/___HR_PLACEHOLDER___/g, '<hr class="doc-separator">');
    html = html.replace(/___H4_START___(.+?)___H4_END___/g, '<h4>$1</h4>');
    html = html.replace(/___H3_START___(.+?)___H3_END___/g, '<h3>$1</h3>');
    html = html.replace(/___H2_START___(.+?)___H2_END___/g, '<h2>$1</h2>');
    html = html.replace(/___H1_START___(.+?)___H1_END___/g, '<h1>$1</h1>');
    html = html.replace(/___BOLD_START___(.+?)___BOLD_END___/g, '<strong>$1</strong>');
    html = html.replace(/___ITALIC_START___(.+?)___ITALIC_END___/g, '<em>$1</em>');

    // Convert list placeholders to HTML and group them
    html = groupListItems(html, 'ULI', 'ul');
    html = groupListItems(html, 'OLI', 'ol');

    // Line breaks for paragraphs (double newline = new paragraph)
    // IMPORTANT: Do this BEFORE restoring code/mermaid placeholders to preserve whitespace in code blocks
    html = html.replace(/\n\n/g, '</p><p>');
    html = '<p>' + html + '</p>';

    // Restore code/table placeholders (need to escape placeholder keys since text was escaped)
    // This is done AFTER paragraph replacement to preserve newlines inside code/mermaid blocks
    for (const [placeholder, content] of Object.entries(placeholders)) {
        html = html.replace(escapeHtml(placeholder), content);
    }

    // Clean up empty paragraphs
    html = html.replace(/<p><\/p>/g, '');
    html = html.replace(/<p>(<h[1234]>)/g, '$1');
    html = html.replace(/(<\/h[1234]>)<\/p>/g, '$1');
    html = html.replace(/<p>(<div class="code-block">)/g, '$1');
    html = html.replace(/<p>(<div class="mermaid-container")/g, '$1');
    html = html.replace(/(<\/div>)<\/p>/g, '$1');
    html = html.replace(/<p>(<ul>)/g, '$1');
    html = html.replace(/(<\/ul>)<\/p>/g, '$1');
    html = html.replace(/<p>(<ol>)/g, '$1');
    html = html.replace(/(<\/ol>)<\/p>/g, '$1');
    html = html.replace(/<p>(<div class="table-wrapper">)/g, '$1');
    html = html.replace(/<p>(<hr)/g, '$1');
    html = html.replace(/(<hr[^>]*>)<\/p>/g, '$1');

    // Prepend frontmatter if present
    return frontmatterHtml + html;
}
