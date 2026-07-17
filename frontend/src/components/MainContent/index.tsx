'use client';

import React from 'react';
import { useSidebar } from '@/components/Sidebar/SidebarProvider';

interface MainContentProps {
  children: React.ReactNode;
}

const MainContent: React.FC<MainContentProps> = ({ children }) => {
  const { isCollapsed } = useSidebar();

  return (
    <main
      id="main-content"
      tabIndex={-1}
      className={`h-dvh min-w-0 overflow-hidden bg-background transition-[margin,width] duration-200 ease-out ${
        isCollapsed
          ? 'ml-[4.5rem] w-[calc(100%-4.5rem)]'
          : 'ml-[15rem] w-[calc(100%-15rem)]'
      }`}
    >
      <div className="flex h-full min-w-0 flex-col">
        {/*
         * Transparent window-drag strip. With the macOS title bar in Overlay
         * mode the content extends to the very top, so this thin region gives
         * a place to drag the window and keeps the content column's top edge
         * aligned with the sidebar's traffic-light clearance. No border/fill —
         * it should read as one continuous surface, not a second bar.
         */}
        <header data-tauri-drag-region aria-hidden="true" className="titlebar h-8 shrink-0" />
        <div className="min-h-0 flex-1 overflow-auto custom-scrollbar">
          {children}
        </div>
      </div>
    </main>
  );
};

export default MainContent;
