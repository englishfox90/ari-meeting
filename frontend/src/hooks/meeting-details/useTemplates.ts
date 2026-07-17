import { useState, useEffect, useCallback, useRef } from 'react';
import { toast } from 'sonner';
import Analytics from '@/lib/analytics';
import { templateService, TemplateInfo } from '@/services/templateService';

export function useTemplates(meetingId?: string) {
  const [availableTemplates, setAvailableTemplates] = useState<TemplateInfo[]>([]);
  const [selectedTemplate, setSelectedTemplate] = useState<string>('standard_meeting');

  // Tracks whether the user explicitly chose a template. While false, summary
  // generation is free to auto-select (F6). Once the user picks one, their
  // choice is authoritative and auto-selection is skipped. A ref (not state)
  // so async generation callbacks read the latest value without re-renders.
  const userSelectedTemplateRef = useRef(false);

  // Fetch available templates on mount
  useEffect(() => {
    const fetchTemplates = async () => {
      try {
        const templates = await templateService.listTemplates();
        console.log('Available templates:', templates);
        setAvailableTemplates(templates);
      } catch (error) {
        console.error('Failed to fetch templates:', error);
      }
    };
    fetchTemplates();
  }, []);

  // Restore the template the existing summary was generated with, so the picker
  // reflects it (including F6 auto-suggested templates) instead of always
  // showing the `standard_meeting` default. Skipped once the user has made an
  // explicit choice this session, and when the meeting has no summary yet
  // (backend returns null → keep the default so first-generation auto-select
  // can still run).
  useEffect(() => {
    if (!meetingId) return;
    let cancelled = false;
    (async () => {
      try {
        const savedTemplate = await templateService.getMeetingTemplate(meetingId);
        if (cancelled || !savedTemplate) return;
        if (userSelectedTemplateRef.current) return;
        setSelectedTemplate(savedTemplate);
      } catch (error) {
        console.error('Failed to load saved meeting template:', error);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [meetingId]);

  // Explicit user selection — becomes authoritative over auto-selection.
  const handleTemplateSelection = useCallback((templateId: string, templateName: string) => {
    userSelectedTemplateRef.current = true;
    setSelectedTemplate(templateId);
    toast.success('Template selected', {
      description: `Using "${templateName}" template for summary generation`,
    });
    Analytics.trackFeatureUsed('template_selected');
  }, []);

  // F6: reflect an auto-selected template in the picker without a toast and
  // without marking it as a user choice (so a later meeting can auto-select
  // again). No-op once the user has made an explicit selection.
  const applySuggestedTemplate = useCallback((templateId: string) => {
    if (userSelectedTemplateRef.current) return;
    setSelectedTemplate(templateId);
  }, []);

  return {
    availableTemplates,
    selectedTemplate,
    handleTemplateSelection,
    applySuggestedTemplate,
    userSelectedTemplateRef,
  };
}
