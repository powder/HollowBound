import os
from playwright.sync_api import sync_playwright, Page, expect

def run_verification(page: Page):
    """
    This test verifies that the widget can run in a serverless, offline
    mode using its local bootstrap data, and that the action progress
    bar appears.
    """
    # 1. Arrange: Go to the local vrpg.html file.
    file_path = os.path.abspath("vrpg.html")
    page.goto(f"file://{file_path}")

    # 2. Act: Wait for an action to begin.
    # We expect the progress bar to become visible.
    expect(page.locator("#action-bar")).to_be_visible(timeout=5000)

    # Then we wait for the quest to complete.
    # The log message for completion is "Finished quest: ..."
    expect(page.locator(".log-line", has_text="Finished quest:")).to_be_visible(timeout=30000)

    # Wait a little longer to see the start of the next cycle.
    page.wait_for_timeout(2000)

    # 3. Screenshot: Capture the final result for visual verification.
    page.screenshot(path="jules-scratch/verification/final_verification.png")

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page()
    run_verification(page)
    browser.close()
