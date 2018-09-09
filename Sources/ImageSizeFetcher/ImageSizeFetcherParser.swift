/*
* ImageSizeFetcher
* Finds the type/size of an image given its URL by fetching as little data as needed
*
* Created by:	Daniele Margutti
* Email:		hello@danielemargutti.com
* Web:			http://www.danielemargutti.com
* Twitter:		@danielemargutti
*
* Copyright © 2018 Daniele Margutti
*
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in
* all copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
* THE SOFTWARE.
*
*/


import UIKit

/// Errors generated by the parser.
///
/// - unsupportedFormat: unsupported image format.
/// - network: network error
public enum ImageParserErrors: Error {
	case unsupportedFormat
	case network(_: Error?)
}

/// Parser is the main core class which parse collected partial data and attempts
/// to get the image format along with the size of the frame.
public class ImageSizeFetcherParser {
	
	/// Supported image formats
	public enum Format {
		case jpeg, png, gif, bmp
		
		/// Minimum amount of data (in bytes) required to parse successfully the frame size.
		/// When `nil` it means the format has a variable data length and therefore
		/// a parsing operation is always required.
		var minimumSample: Int? {
			switch self {
			case .jpeg: return nil // will be checked by the parser (variable data is required)
			case .png: 	return 25
			case .gif: 	return 11
			case .bmp:	return 29
			}
		}
		
		/// Attempt to recognize a known signature from collected partial data.
		///
		/// - Parameter data: partial data from server.
		/// - Throws: throw an exception if file is not supported.
		internal init(fromData data: Data) throws {
			// Evaluate the format of the image
			var length = UInt16(0)
			(data as NSData).getBytes(&length, range: NSRange(location: 0, length: 2))
			switch CFSwapInt16(length) {
			case 0xFFD8:	self = .jpeg
			case 0x8950:	self = .png
			case 0x4749:	self = .gif
			case 0x424D: 	self = .bmp
			default:		throw ImageParserErrors.unsupportedFormat
			}
		}
	}
	
	/// Recognized image format
	public let format: Format
	
	/// Recognized image size
	public let size: CGSize
	
	/// Source image url
	public let sourceURL: URL
	
	/// Data downloaded to parse header informations.
	public private(set) var downloadedData: Int
	
	/// Initialize a new parser from partial data from server.
	///
	/// - Parameter data: partial data from server.
	/// - Throws: throw an exception if file format is not supported by the parser.
	internal init?(sourceURL: URL, _ data: Data) throws {
		let imageFormat = try ImageSizeFetcherParser.Format(fromData: data) // attempt to parse signature
		// if found attempt to parse the frame size
		guard let size = try ImageSizeFetcherParser.imageSize(format: imageFormat, data: data) else {
			return nil // not enough data to format
		}
		// found!
		self.format = imageFormat
		self.size = size
		self.sourceURL = sourceURL
		self.downloadedData = data.count
	}
	
	/// Parse collected data from a specified file format and attempt to get the size of the image frame.
	///
	/// - Parameters:
	///   - format: format of the data.
	///   - data: collected data.
	/// - Returns: size of the image, `nil` if cannot be evaluated with collected data.
	/// - Throws: throw an exception if parser fail or data is corrupted.
	private static func imageSize(format: Format, data: Data) throws -> CGSize? {
		if let minLen = format.minimumSample, data.count <= minLen {
			return nil // not enough data collected to evaluate png size
		}
		
		switch format {
		case .bmp:
			var length: UInt16 = 0
			(data as NSData).getBytes(&length, range: NSRange(location: 14, length: 4))
			
			var w: UInt32 = 0; var h: UInt32 = 0;
			(data as NSData).getBytes(&w, range: (length == 12 ? NSMakeRange(18, 4) : NSMakeRange(18, 2)))
			(data as NSData).getBytes(&h, range: (length == 12 ? NSMakeRange(18, 4) : NSMakeRange(18, 2)))
			
			return CGSize(width: Int(w), height: Int(h))
			
		case .png:
			var w: UInt32 = 0; var h: UInt32 = 0;
			(data as NSData).getBytes(&w, range: NSRange(location: 16, length: 4))
			(data as NSData).getBytes(&h, range: NSRange(location: 20, length: 4))
			
			return CGSize(width: Int(CFSwapInt32(w)), height: Int(CFSwapInt32(h)))
			
		case .gif:
			var w: UInt16 = 0; var h: UInt16 = 0
			(data as NSData).getBytes(&w, range: NSRange(location: 6, length: 2))
			(data as NSData).getBytes(&h, range: NSRange(location: 8, length: 2))
			
			return CGSize(width: Int(w), height: Int(h))
			
		case .jpeg:
			var i: Int = 0
			// check for valid JPEG image
			// http://www.fastgraph.com/help/jpeg_header_format.html
			guard data[i] == 0xFF && data[i+1] == 0xD8 && data[i+2] == 0xFF && data[i+3] == 0xE0 else {
				throw ImageParserErrors.unsupportedFormat // Not a valid SOI header
			}
			i += 4
			
			// Check for valid JPEG header (null terminated JFIF)
			guard data[i+2].char == "J" &&
				data[i+3].char == "F" &&
				data[i+4].char == "I" &&
				data[i+5].char == "F" &&
				data[i+6] == 0x00 else {
					throw ImageParserErrors.unsupportedFormat // Not a valid JFIF string
			}
			
			// Retrieve the block length of the first block since the
			// first block will not contain the size of file
			var block_length: UInt16 = UInt16(data[i]) * 256 + UInt16(data[i+1])
			repeat {
				i += Int(block_length) //I ncrease the file index to get to the next block
				if i >= data.count { // Check to protect against segmentation faults
					return nil
				}
				if data[i] != 0xFF { //Check that we are truly at the start of another block
					return nil
				}
				if data[i+1] >= 0xC0 && data[i+1] <= 0xC3 { // if marker type is SOF0, SOF1, SOF2
					// "Start of frame" marker which contains the file size
					var w: UInt16 = 0; var h: UInt16 = 0;
					(data as NSData).getBytes(&h, range: NSMakeRange(i + 5, 2))
					(data as NSData).getBytes(&w, range: NSMakeRange(i + 7, 2))
					
					let size = CGSize(width: Int(CFSwapInt16(w)), height: Int(CFSwapInt16(h)) );
					return size
				} else {
					// Skip the block marker
					i+=2;
					block_length = UInt16(data[i]) * 256 + UInt16(data[i+1]);   // Go to the next block
				}
			} while (i < data.count)
			return nil
		}
	}
	
}

//MARK: Private UIKit Extensions

private extension Data {
	
	func subdata(in range: ClosedRange<Index>) -> Data {
		return subdata(in: range.lowerBound ..< range.upperBound + 1)
	}
	
	func substring(in range: ClosedRange<Index>) -> String? {
		return String.init(data: self.subdata(in: range), encoding: .utf8)
	}

}

private extension UInt8 {
	
	/// Convert to char
	var char: Character {
		return Character(UnicodeScalar(self))
	}
	
}
