import Foundation
import IceCore
import MediaLibraryKit
import SwiftUI

/// 简易照片日历：年份 → 月份 → 日期，点日期后跳到当天第一张照片。
struct PhotoCalendarMenu: View {
    let calendarIndex: PhotoCalendarIndex
    let onSelect: (PhotoDay) -> Void
    let onSelectMonth: (Int, Int) -> Void
    let onShowAll: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedYear: Int
    @State private var selectedMonth: Int

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = 1
        return calendar
    }()

    init(
        calendarIndex: PhotoCalendarIndex,
        onSelect: @escaping (PhotoDay) -> Void,
        onSelectMonth: @escaping (Int, Int) -> Void,
        onShowAll: @escaping () -> Void
    ) {
        self.calendarIndex = calendarIndex
        self.onSelect = onSelect
        self.onSelectMonth = onSelectMonth
        self.onShowAll = onShowAll
        let year = calendarIndex.years.first ?? Calendar.current.component(.year, from: Date())
        let month = calendarIndex.months(in: year).first ?? 1
        _selectedYear = State(initialValue: year)
        _selectedMonth = State(initialValue: month)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("照片日历", systemImage: "calendar")
                    .font(.headline)
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("calendar.close")
            }

            HStack {
                Picker("年份", selection: $selectedYear) {
                    ForEach(calendarIndex.years, id: \.self) { year in
                        Text(verbatim: "\(year)年").tag(year)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("calendar.yearPicker")

                Spacer()

                Text(verbatim: "\(selectedYear)年\(selectedMonth)月")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .onChange(of: selectedYear) { _, year in
                let months = calendarIndex.months(in: year)
                if !months.contains(selectedMonth) {
                    selectedMonth = months.first ?? 1
                }
            }

            monthGrid
            monthJumpButton
            Divider()
            weekdayHeader
            dayGrid
            Divider()
            Button {
                onShowAll()
                dismiss()
            } label: {
                Label("显示全部照片", systemImage: "photo.stack")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("calendar.showAll")
            .accessibilityLabel("清除日期筛选，显示全部照片")
        }
        .padding(16)
        .frame(width: 350)
        .presentationCompactAdaptation(.popover)
        .accessibilityElement(children: .contain)
    }

    private var monthGrid: some View {
        let counts = Dictionary(
            uniqueKeysWithValues: calendarIndex.monthsWithCounts(in: selectedYear)
                .map { ($0.month, $0.count) }
        )
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4),
            spacing: 6
        ) {
            ForEach(1...12, id: \.self) { month in
                let count = counts[month] ?? 0
                Button {
                    selectedMonth = month
                } label: {
                    VStack(spacing: 1) {
                        Text("\(month)月")
                            .font(.caption.weight(.semibold))
                        Text("\(count)")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .foregroundStyle(
                        month == selectedMonth
                            ? Color.accentColor
                            : (count > 0 ? Color.primary : Color.secondary.opacity(0.45))
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(
                                month == selectedMonth
                                    ? Color.accentColor.opacity(0.16)
                                    : Color(uiColor: .tertiarySystemFill)
                            )
                    )
                }
                .buttonStyle(.plain)
                .disabled(count == 0)
                .accessibilityIdentifier("calendar.month.\(month)")
            }
        }
    }

    private var monthJumpButton: some View {
        let count = calendarIndex.count(in: selectedYear, month: selectedMonth)
        return Button {
            onSelectMonth(selectedYear, selectedMonth)
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "photo.stack")
                    .font(.caption.weight(.semibold))
                Text(verbatim: "查看 \(selectedYear)年\(selectedMonth)月 · \(count) 张照片")
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .accessibilityIdentifier("calendar.monthJump")
        .accessibilityLabel(
            Text(verbatim: "查看 \(selectedYear)年\(selectedMonth)月全部 \(count) 张照片")
        )
    }

    private var weekdayHeader: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7),
            spacing: 4
        ) {
            ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { day in
                Text(day)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var dayGrid: some View {
        let dayCounts = calendarIndex.days(in: selectedYear, month: selectedMonth)
        let firstDate = calendar.date(
            from: DateComponents(year: selectedYear, month: selectedMonth, day: 1)
        ) ?? Date()
        let firstWeekday = calendar.component(.weekday, from: firstDate)
        let leading = max(0, firstWeekday - calendar.firstWeekday)
        let daysInMonth = calendar.range(of: .day, in: .month, for: firstDate)?.count ?? 31

        // 空白占位与日期按钮必须共用唯一 ID，否则 LazyVGrid 会把 1...leading
        // 与 1...daysInMonth 中相同 Int 的单元格合并，导致月初几天消失。
        let cellCount = leading + daysInMonth
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7),
            spacing: 4
        ) {
            ForEach(0..<cellCount, id: \.self) { index in
                if index < leading {
                    Color.clear.frame(height: 34)
                } else {
                    dayCell(day: index - leading + 1, count: dayCounts[index - leading + 1] ?? 0)
                }
            }
        }
    }

    private func dayCell(day: Int, count: Int) -> some View {
        Button {
            onSelect(
                PhotoDay(year: selectedYear, month: selectedMonth, day: day)
            )
            dismiss()
        } label: {
            VStack(spacing: 1) {
                Text(verbatim: "\(day)")
                    .font(.caption.weight(.medium))
                if count > 0 {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 4, height: 4)
                } else {
                    Color.clear.frame(width: 4, height: 4)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 34)
            .foregroundStyle(count > 0 ? Color.primary : Color.secondary.opacity(0.35))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        count > 0
                            ? Color.accentColor.opacity(0.08)
                            : Color.clear
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .accessibilityLabel(
            Text(
                verbatim: "\(selectedYear)年\(selectedMonth)月\(day)日，\(count)张照片"
            )
        )
        .accessibilityIdentifier(
            "calendar.day.\(selectedYear)-\(selectedMonth)-\(day)"
        )
    }
}
