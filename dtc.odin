package dtc

import "core:sys/windows"
import "core:intrinsics"
import "core:os"

L :: intrinsics.constant_utf16_cstring

The_Baby :: struct {
	dwExStyle:    windows.DWORD,
	lpClassName:  windows.LPCWSTR,
	lpWindowName: windows.LPCWSTR,
	dwStyle:      windows.DWORD,
	X:            windows.c_int,
	Y:            windows.c_int,
	nWidth:       windows.c_int,
	nHeight:      windows.c_int,
	hWndParent:   windows.HWND,
	hMenu:        windows.HMENU,
	hInstance:    windows.HINSTANCE,
	lpParam:      windows.LPVOID,
}

CREATE_DANGEROUS_WINDOW :: windows.WM_USER + 0x1337
DESTROY_DANGEROUS_WINDOW :: windows.WM_USER + 0x1338

main_thread_ID: windows.DWORD

display_wnd_proc :: proc "stdcall" (window: windows.HWND, message: windows.UINT, wparam: windows.WPARAM, lparam: windows.LPARAM) -> (result: windows.LRESULT) {
	/* NOTE(casey): This is an example of an actual window procedure. It doesn't do anything
		 but forward things to the main thread, because again, all window messages now occur
		 on the message thread, and presumably we would rather handle everything there.  You
		 don't _have_ to do that - you could choose to handle some of the messages here.
		 But if you did, you would have to actually think about whether there are race conditions
		 with your main thread and all that.  So just PostThreadMessageW()'ing everything gets
		 you out of having to think about it.
	*/

	switch message {
	// NOTE(casey): Mildly annoying, if you want to specify a window, you have
	// to snuggle the params yourself, because Windows doesn't let you forward
	// a god damn window message even though the program IS CALLED WINDOWS. It's
	// in the name! Let me pass it!
	case windows.WM_CLOSE:
		windows.PostThreadMessageW(main_thread_ID, message, windows.WPARAM(window), lparam)

	// NOTE(casey): Anything you want the application to handle, forward to the main thread
	// here.
	case windows.WM_MOUSEMOVE, windows.WM_LBUTTONDOWN, windows.WM_LBUTTONUP, windows.WM_DESTROY, windows.WM_CHAR:
		windows.PostThreadMessageW(main_thread_ID, message, wparam, lparam)

	case:
		result = windows.DefWindowProcW(window, message, wparam, lparam)
	}

	return
}

main_thread :: proc "stdcall" (param: windows.LPVOID) -> windows.DWORD {
	/* NOTE(Casey): This is your app code. Basically you just do everything the same,
		 but instead of calling CreateWindow/DestroyWindow, you use SendMessage to
		 do it on the other thread, using the CREATE_DANGEROUS_WINDOW and DESTROY_DANGEROUS_WINDOW
		 user messages.  Otherwise, everything proceeds as normal.
	*/
	instance := windows.HINSTANCE(windows.GetModuleHandleW(nil))

	service_window := windows.HWND(param)

	baby_window_class: windows.WNDCLASSEXW = {
		cbSize = size_of(windows.WNDCLASSEXW),
		lpfnWndProc = display_wnd_proc,
		hInstance = instance,
		hIcon = windows.LoadIconA(nil, windows.IDI_APPLICATION),
		hCursor = windows.LoadCursorA(nil, windows.IDC_ARROW),
		hbrBackground = windows.HBRUSH(windows.GetStockObject(windows.BLACK_BRUSH)),
		lpszClassName = L("Dangerous Class"),
	}
	windows.RegisterClassExW(&baby_window_class)

	baby: The_Baby = {
		lpClassName = baby_window_class.lpszClassName,
		lpWindowName = L("Dangerous Window"),
		dwStyle = windows.WS_OVERLAPPEDWINDOW | windows.WS_VISIBLE,
		X = windows.CW_USEDEFAULT,
		Y = windows.CW_USEDEFAULT,
		nWidth = windows.CW_USEDEFAULT,
		nHeight = windows.CW_USEDEFAULT,
		hInstance = baby_window_class.hInstance,
	}
	result := windows.SendMessageW(service_window, CREATE_DANGEROUS_WINDOW, cast(windows.WPARAM)&baby, 0)
	this_would_be_the_handle_if_you_cared := windows.HWND(uintptr(result))
	_ = this_would_be_the_handle_if_you_cared

	x: i32
	for {
		message: windows.MSG = ---
		for windows.PeekMessageW(&message, nil, 0, 0, windows.PM_REMOVE) {
			switch message.message {
			case windows.WM_CHAR:
				windows.SendMessageW(service_window, CREATE_DANGEROUS_WINDOW, cast(windows.WPARAM)&baby, 0)
			case windows.WM_CLOSE:
				windows.SendMessageW(service_window, DESTROY_DANGEROUS_WINDOW, message.wParam, 0)
			}
		}

		mid_point := (x%(64*1024))/64
		x += 1

		window_count: i32
		for window := windows.FindWindowExW(nil, nil, baby_window_class.lpszClassName, nil)
		window != nil;
		window = windows.FindWindowExW(nil, window, baby_window_class.lpszClassName, nil) {
			client: windows.RECT = ---
			windows.GetClientRect(window, &client)
			dc := windows.GetDC(window)

			windows.PatBlt(dc, 0, 0, mid_point, client.bottom, windows.BLACKNESS)
			if client.right > mid_point {
				windows.PatBlt(dc, mid_point, 0, client.right - mid_point, client.bottom, windows.WHITENESS)
			}
			windows.ReleaseDC(window, dc)

			window_count += 1
		}

		if window_count == 0 do break
	}

	os.exit(0)
}

service_wnd_proc :: proc "stdcall" (window: windows.HWND, message: windows.UINT, wparam: windows.WPARAM, lparam: windows.LPARAM) -> (result: windows.LRESULT) {
	/* NOTE(casey): This is not really a window handler per se, it's actually just
		 a remote thread call handler. Windows only really has blocking remote thread
		 calls if you register a WndProc for them, so that's what we do.

		 This handles CREATE_DANGEROUS_WINDOW and DESTROY_DANGEROUS_WINDOW, which are
		 just calls that do CreateWindow and DestroyWindow here on this thread when
		 some other thread wants that to happen.
	*/

	switch message {
	case CREATE_DANGEROUS_WINDOW:
		baby := cast(^The_Baby)wparam
		wnd := windows.CreateWindowExW(
			baby.dwExStyle,
			baby.lpClassName,
			baby.lpWindowName,
			baby.dwStyle,
			baby.X,
			baby.Y,
			baby.nWidth,
			baby.nHeight,
			baby.hWndParent,
			baby.hMenu,
			baby.hInstance,
			baby.lpParam,
		)
		result = windows.LRESULT(uintptr(wnd))
	case DESTROY_DANGEROUS_WINDOW:
		windows.DestroyWindow(windows.HWND(wparam))
	case:
		result = windows.DefWindowProcW(window, message, wparam, lparam)
	}

	return
}

main :: proc() {
	instance := windows.HINSTANCE(windows.GetModuleHandleW(nil))
	assert(instance != nil, "Failed to detect default instance")

	/* NOTE(casey): At startup, you create one hidden window used to handle requests
		 to create or destroy windows.  There's nothing special about this window; it
		 only exists because Windows doesn't have a way to do a remote thread call without
		 a window handler.  You could instead just do this with your own synchronization
		 primitives if you wanted - this is just the easiest way to do it on Windows
		 because they've already built it for you.
	*/

	service_window_class: windows.WNDCLASSEXW = {
		cbSize = size_of(windows.WNDCLASSEXW),
		lpfnWndProc = service_wnd_proc,
		hInstance = instance,
		hIcon = windows.LoadIconA(nil, windows.IDI_APPLICATION),
		hCursor = windows.LoadCursorA(nil, windows.IDC_ARROW),
		hbrBackground = windows.HBRUSH(windows.GetStockObject(windows.BLACK_BRUSH)),
		lpszClassName = L("DTCClass"),
	}
	windows.RegisterClassExW(&service_window_class)

	service_window := windows.CreateWindowExW(
		0, service_window_class.lpszClassName, L("DTCService"), 0,
		windows.CW_USEDEFAULT, windows.CW_USEDEFAULT,
		windows.CW_USEDEFAULT, windows.CW_USEDEFAULT,
		nil, nil, service_window_class.hInstance, nil,
	)

	// NOTE(casey): Once the service window is created, you can start the main thread,
	// which is where all your app code would actually happen.
	windows.CreateThread(nil, 0, main_thread, service_window, 0, &main_thread_ID)

	// NOTE(casey): This thread can just idle for the rest of the run, forwarding
	// messages to the main thread that it thinks the main thread wants.
	for {
		message: windows.MSG = ---
		windows.GetMessageW(&message, nil, 0, 0)
		windows.TranslateMessage(&message)

		switch message.message {
		case windows.WM_CHAR, windows.WM_KEYDOWN, windows.WM_QUIT, windows.WM_SIZE:
			windows.PostThreadMessageW(main_thread_ID, message.message, message.wParam, message.lParam)
		case:
			windows.DispatchMessageW(&message)
		}
	}
}
